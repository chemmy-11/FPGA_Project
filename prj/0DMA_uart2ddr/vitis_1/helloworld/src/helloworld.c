#include "platform.h"
#include "xaxidma.h"
#include "xil_cache.h"
#include "xil_exception.h"
#include "xil_printf.h"
#include "xil_types.h"
#include "xparameters.h"
#include "xstatus.h"
#include "xintc.h"

/*
 * ============================================================
 *  功能：
 *
 *  1 + 回车：
 *      进入数据输入模式
 *      用户继续输入任意长度数据
 *      再按一次回车结束
 *      程序通过 DMA 回环把该数据存入 DDR 的一个记录区
 *
 *  2 + 回车：
 *      输入记录编号
 *      DMA 从 DDR 对应记录区读出数据到读回缓冲区
 *      MicroBlaze 再通过 UART 打印到串口助手
 *
 *  注意：
 *      由于 AXI UARTLite 不是 AXI-Stream 接口，
 *      所以 DMA 不能直接把数据送到 UART。
 *      当前方案是：
 *
 *      UART → MicroBlaze → DDR源缓冲区 → DMA → DDR记录区
 *      DDR记录区 → DMA → DDR读回缓冲区 → MicroBlaze → UART
 * ============================================================
 */

#define DMA_DEV_ID          XPAR_AXIDMA_0_DEVICE_ID
#define INTC_DEV_ID         XPAR_INTC_0_DEVICE_ID
#define EXPAND_FACTOR       10U


#define MM2S_INTRO_INTR_ID  XPAR_INTC_0_AXIDMA_0_MM2S_INTROUT_VEC_ID
#define S2MM_INTRO_INTR_ID  XPAR_INTC_0_AXIDMA_0_S2MM_INTROUT_VEC_ID

#define DMA_ALIGN_BYTES     4U
#define DMA_TIMEOUT         10000000U

#ifdef XPAR_DDR4_0_BASEADDR
#define DDR_BASE_ADDR       XPAR_DDR4_0_BASEADDR
#else
#define DDR_BASE_ADDR       0x80000000U
#endif

/*
 * DDR 地址规划
 *
 * UART_RX_BUF_BASE：
 *      MicroBlaze 接收串口数据时，先把数据放到这里。
 *
 * RECORD_BASE：
 *      DMA 最终把数据搬到这里，每条记录占 RECORD_SLOT_SIZE。
 *
 * DDR_READBACK_BASE：
 *      读取记录时，DMA 先把指定记录搬到这里，
 *      然后 MicroBlaze 再从这里 outbyte() 发回串口助手。
 */
#define UART_RX_BUF_BASE    (DDR_BASE_ADDR + 0x00100000U)
#define RECORD_BASE         (DDR_BASE_ADDR + 0x00200000U)
#define DDR_READBACK_BASE   (DDR_BASE_ADDR + 0x00A00000U)

#define MAX_RECORDS         16U  //最大记录16条数据
#define RECORD_SLOT_SIZE    (64U * 1024U)
#define UART_MAX_LEN        (RECORD_SLOT_SIZE - DMA_ALIGN_BYTES)
#define UART_MAX_INPUT_LEN  (UART_MAX_LEN / EXPAND_FACTOR)

/*
 * 每条记录的目标 DDR 地址：
 *
 * Record 0: RECORD_BASE + 0 * RECORD_SLOT_SIZE
 * Record 1: RECORD_BASE + 1 * RECORD_SLOT_SIZE
 * Record 2: RECORD_BASE + 2 * RECORD_SLOT_SIZE
 */
#define RECORD_ADDR(Index)  (RECORD_BASE + ((Index) * RECORD_SLOT_SIZE))

static XAxiDma AxiDma;
static XIntc Intc;

static volatile int TxDone;
static volatile int RxDone;
static volatile int Error;

/*
 * 保存每一次写入的数据长度。
 * RecordLen[i] = 0 表示该记录不存在。
 */
static u32 RecordLen[MAX_RECORDS];
static u32 RecordCount = 0U;


/* ============================================================
 *  DMA 中断服务函数
 * ============================================================
 */

static void DmaTxInterruptHandler(void *Callback)
{
    XAxiDma *XAxiDmaPtr = (XAxiDma *)Callback;
    u32 IrqStatus;

    IrqStatus = XAxiDma_IntrGetIrq(XAxiDmaPtr, XAXIDMA_DMA_TO_DEVICE);
    XAxiDma_IntrAckIrq(XAxiDmaPtr, IrqStatus, XAXIDMA_DMA_TO_DEVICE);

    if (IrqStatus & XAXIDMA_IRQ_ERROR_MASK) {
        Error = 1;
        return;
    }

    if (IrqStatus & XAXIDMA_IRQ_IOC_MASK) {
        TxDone = 1;
    }
}

static void DmaRxInterruptHandler(void *Callback)
{
    XAxiDma *XAxiDmaPtr = (XAxiDma *)Callback;
    u32 IrqStatus;

    IrqStatus = XAxiDma_IntrGetIrq(XAxiDmaPtr, XAXIDMA_DEVICE_TO_DMA);
    XAxiDma_IntrAckIrq(XAxiDmaPtr, IrqStatus, XAXIDMA_DEVICE_TO_DMA);

    if (IrqStatus & XAXIDMA_IRQ_ERROR_MASK) {
        Error = 1;
        return;
    }

    if (IrqStatus & XAXIDMA_IRQ_IOC_MASK) {
        RxDone = 1;
    }
}


/* ============================================================
 *  中断系统初始化
 * ============================================================
 */

static int SetupInterruptSystem(XIntc *IntcInstancePtr,
                                XAxiDma *AxiDmaPtr,
                                u16 TxIntrId,
                                u16 RxIntrId)
{
    int Status;

    Status = XIntc_Initialize(IntcInstancePtr, INTC_DEV_ID);
    if (Status != XST_SUCCESS) {
        return XST_FAILURE;
    }

    Status = XIntc_Connect(IntcInstancePtr,
                           TxIntrId,
                           (XInterruptHandler)DmaTxInterruptHandler,
                           AxiDmaPtr);
    if (Status != XST_SUCCESS) {
        return XST_FAILURE;
    }

    Status = XIntc_Connect(IntcInstancePtr,
                           RxIntrId,
                           (XInterruptHandler)DmaRxInterruptHandler,
                           AxiDmaPtr);
    if (Status != XST_SUCCESS) {
        return XST_FAILURE;
    }

    Status = XIntc_Start(IntcInstancePtr, XIN_REAL_MODE);
    if (Status != XST_SUCCESS) {
        return XST_FAILURE;
    }

    XIntc_Enable(IntcInstancePtr, TxIntrId);
    XIntc_Enable(IntcInstancePtr, RxIntrId);

    Xil_ExceptionInit();
    Xil_ExceptionRegisterHandler(XIL_EXCEPTION_ID_INT,
                                 (Xil_ExceptionHandler)XIntc_InterruptHandler,
                                 IntcInstancePtr);
    Xil_ExceptionEnable();

    return XST_SUCCESS;
}


/* ============================================================
 *  DMA 初始化
 * ============================================================
 */

static int init_dma(void)
{
    XAxiDma_Config *CfgPtr;
    int Status;
    u32 Timeout;

    CfgPtr = XAxiDma_LookupConfig(DMA_DEV_ID);
    if (CfgPtr == NULL) {
        xil_printf("ERROR: DMA config not found.\r\n");
        return XST_FAILURE;
    }

    Status = XAxiDma_CfgInitialize(&AxiDma, CfgPtr);
    if (Status != XST_SUCCESS) {
        xil_printf("ERROR: DMA init failed: %d\r\n", Status);
        return XST_FAILURE;
    }

    if (XAxiDma_HasSg(&AxiDma)) {
        xil_printf("ERROR: DMA is in SG mode; this code expects Simple DMA mode.\r\n");
        return XST_FAILURE;
    }

    XAxiDma_Reset(&AxiDma);

    Timeout = DMA_TIMEOUT;
    while (!XAxiDma_ResetIsDone(&AxiDma)) {
        if (--Timeout == 0U) {
            xil_printf("ERROR: DMA reset timeout.\r\n");
            return XST_FAILURE;
        }
    }

    XAxiDma_IntrDisable(&AxiDma,
                        XAXIDMA_IRQ_ALL_MASK,
                        XAXIDMA_DMA_TO_DEVICE);

    XAxiDma_IntrDisable(&AxiDma,
                        XAXIDMA_IRQ_ALL_MASK,
                        XAXIDMA_DEVICE_TO_DMA);

    XAxiDma_IntrEnable(&AxiDma,
                       XAXIDMA_IRQ_IOC_MASK | XAXIDMA_IRQ_ERROR_MASK,
                       XAXIDMA_DMA_TO_DEVICE);

    XAxiDma_IntrEnable(&AxiDma,
                       XAXIDMA_IRQ_IOC_MASK | XAXIDMA_IRQ_ERROR_MASK,
                       XAXIDMA_DEVICE_TO_DMA);

    return XST_SUCCESS;
}


/* ============================================================
 *  工具函数
 * ============================================================
 */

static u32 align_up(u32 value, u32 align)
{
    return (value + align - 1U) & ~(align - 1U);
}

static void clear_buffer(u8 *Buf, u32 Length)
{
    u32 i;

    for (i = 0U; i < Length; i++) {
        Buf[i] = 0U;
    }
}

static void print_menu(void)
{
    xil_printf("\r\n");
    xil_printf("============================================\r\n");
    xil_printf(" UART + DMA + DDR Demo\r\n");
    xil_printf("============================================\r\n");
    xil_printf("Command:\r\n");
    xil_printf("  1 + Enter : input data, then DMA write to DDR\r\n");
    xil_printf("  2 + Enter : select record, DMA read from DDR, print to UART\r\n");
    xil_printf("  l + Enter : list records\r\n");
    xil_printf("============================================\r\n");
    xil_printf("Input command: ");
}

/*
 * 丢弃当前行剩余字符。
 *
 * 例如串口助手发送：
 *      1\r\n
 *
 * 主循环先读到 '1'，
 * 但后面还会残留 '\r' 或 '\n'，
 * 所以要把这一行剩下的回车换行吃掉。
 */
static void discard_until_newline(void)
{
    char ch;

    while (1) {
        ch = inbyte();

        if (ch == '\r' || ch == '\n') {
            /*
             * 对于 \r\n 的情况，可能还剩一个 \n。
             * 这里不强制继续读，否则可能阻塞。
             */
            break;
        }
    }
}

/*
 * 从 UART 接收一行数据，并把每个字符扩展成 10 个相同字符。
 *
 * 例如串口输入：
 *      123
 *
 * DDR源缓冲区中实际保存：
 *      111111111122222222223333333333
 *
 * 返回值：
 *      扩展后的长度，不是原始输入长度。
 */
static u32 receive_line_expand_to_buffer(u8 *Buf, u32 MaxExpandedLen)
{
    u32 ExpandedLen = 0U;
    u32 InputLen = 0U;
    u32 i;
    char ch;

    while (1) {
        ch = inbyte();

        if (ch == '\r' || ch == '\n') {
            break;
        }

        /*
         * 判断再写入 10 个字符是否会超过缓冲区。
         */
        if ((ExpandedLen + EXPAND_FACTOR) <= MaxExpandedLen) {

            /*
             * 回显用户原始输入的字符。
             * 例如用户输入 1，只在串口助手显示一个 1，
             * 但 DDR 源缓冲区里写入 10 个 1。
             */
            outbyte(ch);

            for (i = 0U; i < EXPAND_FACTOR; i++) {
                Buf[ExpandedLen] = (u8)ch;
                ExpandedLen++;
            }

            InputLen++;
        } else {
            xil_printf("\r\nWARNING: input too long. Extra data ignored until Enter.\r\n");

            /*
             * 如果超过最大长度，丢弃后续字符直到回车。
             */
            while (1) {
                ch = inbyte();

                if (ch == '\r' || ch == '\n') {
                    break;
                }
            }

            break;
        }
    }

    xil_printf("\r\n");
    xil_printf("Original input length : %d bytes\r\n", InputLen);
    xil_printf("Expanded DMA length   : %d bytes\r\n", ExpandedLen);

    return ExpandedLen;
}

/*
 * 读取一个十进制数字，例如：
 *      0 + Enter
 *      1 + Enter
 *      12 + Enter
 *
 * 返回值：
 *      解析出的数字
 */
static u32 receive_decimal_number(void)
{
    u32 Value = 0U;
    char ch;

    while (1) {
        ch = inbyte();

        if (ch == '\r' || ch == '\n') {
            break;
        }

        if (ch >= '0' && ch <= '9') {
            outbyte(ch);
            Value = Value * 10U + (u32)(ch - '0');
        }
    }

    xil_printf("\r\n");

    return Value;
}


/* ============================================================
 *  DMA 回环搬运函数
 *
 *  功能：
 *      SrcBuffer → DMA MM2S → AXIS FIFO → DMA S2MM → DstBuffer
 *
 *  也就是：
 *      DDR源地址 → DMA → FIFO → DMA → DDR目标地址
 * ============================================================
 */

static int dma_copy_via_axis_loopback(u8 *SrcBuffer, u8 *DstBuffer, u32 Length)
{
    u32 DmaLength;
    u32 i;
    u32 Timeout;
    int Status;

    if (Length == 0U) {
        return XST_SUCCESS;
    }

    DmaLength = align_up(Length, DMA_ALIGN_BYTES);

    /*
     * 如果长度不是 4 字节对齐，补 0。
     * 例如实际 5 字节，DMA 搬 8 字节。
     * 但记录的真实长度仍然是 5。
     */
    for (i = Length; i < DmaLength; i++) {
        SrcBuffer[i] = 0U;
    }

    /*
     * 清空目标区域，避免读回时看到旧数据。
     */
    clear_buffer(DstBuffer, DmaLength);

    /*
     * Cache 处理非常重要：
     *
     * MM2S 方向：
     *      DMA 要从 SrcBuffer 读，所以 CPU 必须先 Flush。
     *
     * S2MM 方向：
     *      DMA 要写 DstBuffer，所以 CPU 后面读之前必须 Invalidate。
     */
    Xil_DCacheFlushRange((UINTPTR)SrcBuffer, DmaLength);
    Xil_DCacheFlushRange((UINTPTR)DstBuffer, DmaLength);

    TxDone = 0;
    RxDone = 0;
    Error  = 0;

    /*
     * 必须先启动 S2MM 接收，再启动 MM2S 发送。
     * 否则 MM2S 已经开始输出流了，但 S2MM 还没准备好，容易卡住。
     */
    Status = XAxiDma_SimpleTransfer(&AxiDma,
                                    (UINTPTR)DstBuffer,
                                    DmaLength,
                                    XAXIDMA_DEVICE_TO_DMA);
    if (Status != XST_SUCCESS) {
        xil_printf("ERROR: S2MM start failed: %d\r\n", Status);
        return XST_FAILURE;
    }

    Status = XAxiDma_SimpleTransfer(&AxiDma,
                                    (UINTPTR)SrcBuffer,
                                    DmaLength,
                                    XAXIDMA_DMA_TO_DEVICE);
    if (Status != XST_SUCCESS) {
        xil_printf("ERROR: MM2S start failed: %d\r\n", Status);
        return XST_FAILURE;
    }

    Timeout = DMA_TIMEOUT;

    while (!TxDone || !RxDone) {
        if (Error) {
            xil_printf("ERROR: DMA internal error.\r\n");
            return XST_FAILURE;
        }

        if (--Timeout == 0U) {
            xil_printf("ERROR: DMA timeout. TxDone=%d, RxDone=%d\r\n",
                       TxDone, RxDone);
            return XST_FAILURE;
        }
    }

    Xil_DCacheInvalidateRange((UINTPTR)DstBuffer, DmaLength);

    return XST_SUCCESS;
}


/* ============================================================
 *  功能 1：UART 输入数据，然后 DMA 写入 DDR 记录区
 * ============================================================
 */
static int handle_write_record(void)
{
    u8 *RxBuf;
    u8 *RecordDst;
    u32 Len;
    u32 RecordIndex;
    int Status;

    if (RecordCount >= MAX_RECORDS) {
        xil_printf("\r\nERROR: record table full. MAX_RECORDS=%d\r\n", MAX_RECORDS);
        return XST_FAILURE;
    }

    RxBuf = (u8 *)UART_RX_BUF_BASE;
    RecordIndex = RecordCount;
    RecordDst = (u8 *)RECORD_ADDR(RecordIndex);

    xil_printf("\r\nInput data now, press Enter to finish:\r\n");
    xil_printf("Each input character will be expanded to %d same characters.\r\n",
               EXPAND_FACTOR);

    /*
     * 清空 DDR 源缓冲区。
     */
    clear_buffer(RxBuf, UART_MAX_LEN + DMA_ALIGN_BYTES);

    /*
     * 注意：
     * 这里返回的是扩展后的长度。
     *
     * 例如输入 123456qwerty：
     * 原始长度 11 字节
     * 扩展后长度 110 字节
     */
    Len = receive_line_expand_to_buffer(RxBuf, UART_MAX_LEN);

    if (Len == 0U) {
        xil_printf("No data received. Record not saved.\r\n");
        return XST_FAILURE;
    }

    xil_printf("Start DMA write expanded data to DDR record %d...\r\n", RecordIndex);

    Status = dma_copy_via_axis_loopback(RxBuf, RecordDst, Len);

    if (Status != XST_SUCCESS) {
        xil_printf("ERROR: DMA write record failed.\r\n");
        return Status;
    }

    RecordLen[RecordIndex] = Len;
    RecordCount++;

    xil_printf("DMA write done.\r\n");
    xil_printf("Record ID        : %d\r\n", RecordIndex);
    xil_printf("DDR address      : 0x%08x\r\n", (u32)RECORD_ADDR(RecordIndex));
    xil_printf("DMA write length : %d bytes\r\n", Len);

    return XST_SUCCESS;
}

/* ============================================================
 *  功能 2：选择记录，DMA 从 DDR 读出，再通过 UART 打印
 * ============================================================
 */

static int handle_read_record(void)
{
    u32 RecordIndex;
    u32 Len;
    u8 *RecordSrc;
    u8 *ReadbackBuf;
    u32 i;
    int Status;

    if (RecordCount == 0U) {
        xil_printf("\r\nNo records saved yet.\r\n");
        return XST_FAILURE;
    }

    xil_printf("\r\nCurrent records:\r\n");

    for (i = 0U; i < RecordCount; i++) {
        xil_printf("  Record %d: addr=0x%08x, len=%d bytes\r\n",
                   i,
                   (u32)RECORD_ADDR(i),
                   RecordLen[i]);
    }

    xil_printf("Input record ID to read: ");

    RecordIndex = receive_decimal_number();

    if (RecordIndex >= RecordCount) {
        xil_printf("ERROR: invalid record ID %d. Current max ID is %d.\r\n",
                   RecordIndex,
                   RecordCount - 1U);
        return XST_FAILURE;
    }

    Len = RecordLen[RecordIndex];

    if (Len == 0U) {
        xil_printf("ERROR: selected record is empty.\r\n");
        return XST_FAILURE;
    }

    RecordSrc = (u8 *)RECORD_ADDR(RecordIndex);
    ReadbackBuf = (u8 *)DDR_READBACK_BASE;

    xil_printf("Start DMA read record %d from DDR...\r\n", RecordIndex);

    Status = dma_copy_via_axis_loopback(RecordSrc, ReadbackBuf, Len);

    if (Status != XST_SUCCESS) {
        xil_printf("ERROR: DMA read record failed.\r\n");
        return Status;
    }

    Xil_DCacheInvalidateRange((UINTPTR)ReadbackBuf, align_up(Len, DMA_ALIGN_BYTES));

    xil_printf("DMA read done.\r\n");
    xil_printf("Record %d content:\r\n", RecordIndex);

    for (i = 0U; i < Len; i++) {
        outbyte((char)ReadbackBuf[i]);
    }

    xil_printf("\r\n");

    return XST_SUCCESS;
}


/* ============================================================
 *  列出所有已保存记录
 * ============================================================
 */

static void list_records(void)
{
    u32 i;

    xil_printf("\r\nRecord list:\r\n");

    if (RecordCount == 0U) {
        xil_printf("  No records.\r\n");
        return;
    }

    for (i = 0U; i < RecordCount; i++) {
        xil_printf("  Record %d: addr=0x%08x, len=%d bytes\r\n",
                   i,
                   (u32)RECORD_ADDR(i),
                   RecordLen[i]);
    }
}


/* ============================================================
 *  主控制循环
 * ============================================================
 */

static void uart_dma_control_loop(void)
{
    char Cmd;

    print_menu();

    while (1) {
        Cmd = inbyte();

        if (Cmd == '1') {
            discard_until_newline();
            handle_write_record();
            print_menu();
        }
        else if (Cmd == '2') {
            discard_until_newline();
            handle_read_record();
            print_menu();
        }
        else if (Cmd == 'l' || Cmd == 'L') {
            discard_until_newline();
            list_records();
            print_menu();
        }
        else if (Cmd == '\r' || Cmd == '\n') {
            /*
             * 忽略空行。
             */
        }
        else {
            xil_printf("\r\nUnknown command: %c\r\n", Cmd);
            xil_printf("Please input 1, 2, or l.\r\n");
            print_menu();
        }
    }
}


/* ============================================================
 *  main
 * ============================================================
 */

int main(void)
{
    u32 i;

    init_platform();

    for (i = 0U; i < MAX_RECORDS; i++) {
        RecordLen[i] = 0U;
    }

    xil_printf("\r\n============================================\r\n");
    xil_printf(" UART Controlled DMA DDR Storage Demo\r\n");
    xil_printf("============================================\r\n");
    xil_printf("UART baudrate: %d\r\n", (u32)XPAR_UARTLITE_0_BAUDRATE);
    xil_printf("DDR_BASE_ADDR      = 0x%08x\r\n", (u32)DDR_BASE_ADDR);
    xil_printf("UART_RX_BUF_BASE   = 0x%08x\r\n", (u32)UART_RX_BUF_BASE);
    xil_printf("RECORD_BASE        = 0x%08x\r\n", (u32)RECORD_BASE);
    xil_printf("DDR_READBACK_BASE  = 0x%08x\r\n", (u32)DDR_READBACK_BASE);
    xil_printf("MAX_RECORDS        = %d\r\n", MAX_RECORDS);
    xil_printf("RECORD_SLOT_SIZE   = %d bytes\r\n", RECORD_SLOT_SIZE);
    xil_printf("UART_MAX_LEN       = %d bytes\r\n", UART_MAX_LEN);

    if (init_dma() != XST_SUCCESS) {
        xil_printf("DMA initialization failed.\r\n");
        cleanup_platform();
        return XST_FAILURE;
    }

    xil_printf("DMA initialized.\r\n");

    if (SetupInterruptSystem(&Intc,
                             &AxiDma,
                             MM2S_INTRO_INTR_ID,
                             S2MM_INTRO_INTR_ID) != XST_SUCCESS) {
        xil_printf("Interrupt system setup failed.\r\n");
        cleanup_platform();
        return XST_FAILURE;
    }

    xil_printf("Interrupt system initialized.\r\n");

    uart_dma_control_loop();

    cleanup_platform();
    return XST_SUCCESS;
}
