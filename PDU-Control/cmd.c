#include "cmd.h"
#include "char.h"
#include "macros.h"
#include "memory.h"
#include "mmap.h"
#include "uart_io.h"

#define NOT_ALIGNED true
#define OUT_OF_RANGE true

static bool get_token(char * _token, unsigned long _tokenSize, const char * _line, unsigned long _lineSize, unsigned long * _offset) {
    int c;
    while(is_ws(c = load_byte(_line + *_offset)) && *_offset < _lineSize) {
        (*_offset)++;
    }
    if(*_offset == _lineSize || !is_alpha(c)) {
        return false;
    }
    unsigned long i = 0;
    while(is_alpha(c = load_byte(_line + *_offset)) && *_offset < _lineSize && i < _tokenSize - 1) {
        store_byte(_token + i++, c);
        (*_offset)++;
    }
    store_byte(_token + i, '\0');
    return true;
}

static bool get_uint32(unsigned int * _hex, const char * _line, unsigned long _lineSize, unsigned long * _offset) {
    int c;
    while(is_ws(c = load_byte(_line + *_offset)) && *_offset < _lineSize) {
        (*_offset)++;
    }
    if(c == '0' && load_byte(_line + ++(*_offset)) == 'x') {
        (*_offset)++;
        *_hex = 0;
        int count = 0;
        while(count < 8 && is_hex(c = load_byte(_line + *_offset)) && *_offset < _lineSize) {
            *_hex <<= 4;
            if(c >= '0' && c <= '9') {
                *_hex += c - '0';
            }
            else if(c >= 'a' && c <= 'f') {
                *_hex += c - 'a' + 10;
            }
            else {
                *_hex += c - 'A' + 10;
            }
            count++;
            (*_offset)++;
        }
        if(count == 8 && is_hex(load_byte(_line + *_offset)) && *_offset < _lineSize) {
            uart_puts("\n\rNumber out of range of 32-bit unsigned integer\n\r");
            while(is_hex(load_byte(_line + *_offset)) && *_offset < _lineSize) {
                (*_offset)++;
            }
            return false;
        }
        return true;
    }
    if(is_digit(c)) {
        *_hex = c - '0';
        (*_offset)++;
        while(is_digit(c = load_byte(_line + *_offset)) && *_offset < _lineSize) {
            if(*_hex > 429496729 || *_hex == 429496729 && c > '5') {
                uart_puts("\n\rNumber out of range of 32-bit unsigned integer\n\r");
                while(is_digit(load_byte(_line + *_offset)) && *_offset < _lineSize) {
                    (*_offset)++;
                }
                return false;
            }
            *_hex *= 10;
            *_hex += c - '0';
            (*_offset)++;
        }
        return true;
    }
    uart_puts("\n\rUnexpected character: ");
    uart_putc(c);
    uart_puts("\n\r");
    return false;
}

static bool get_uint32_or_none(unsigned int * _hex, const char * _line, unsigned long _lineSize, unsigned long * _offset) {
    int c;
    while(is_ws(c = load_byte(_line + *_offset)) && *_offset < _lineSize) {
        (*_offset)++;
    }
    if(c == '\0' || c == '\n' || c == '\r') {
        *_hex = 1;
        return true;
    }
    if(c == '0' && load_byte(_line + *_offset) == 'x') {
        (*_offset)++;
        *_hex = 0;
        int count = 0;
        while(count < 8 && is_hex(c = load_byte(_line + *_offset)) && *_offset < _lineSize) {
            *_hex <<= 4;
            if(c >= '0' && c <= '9') {
                *_hex += c - '0';
            }
            else if(c >= 'a' && c <= 'f') {
                *_hex += c - 'a' + 10;
            }
            else {
                *_hex += c - 'A' + 10;
            }
            count++;
            (*_offset)++;
        }
        if(count == 8 && is_hex(load_byte(_line + *_offset)) && *_offset < _lineSize) {
            uart_puts("\n\rNumber out of range of 32-bit unsigned integer\n\r");
            return false;
        }
        return true;
    }
    if(is_digit(c)) {
        *_hex = c - '0';
        (*_offset)++;
        while(is_digit(c = load_byte(_line + *_offset)) && *_offset < _lineSize) {
            if(*_hex > 429496729 || *_hex == 429496729 && c > '5') {
                uart_puts("\n\rNumber out of range of 32-bit unsigned integer\n\r");
                return false;
            }
            *_hex *= 10;
            *_hex += c - '0';
            (*_offset)++;
        }
        return true;
    }
    uart_puts("\n\rUnexpected character: ");
    uart_putc(c);
    uart_puts("\n\r");
    return false;
}

static bool has_more_token(const char * _line, unsigned long _lineSize, unsigned long _offset) {
    int c;
    while(_offset < _lineSize && is_ws(c = load_byte(_line + _offset))) {
        _offset++;
    }
    c = load_byte(_line + _offset);
    return !(c == '\0' || c == '\n' || c == '\r');
}

static int strcmp(const char * _s1, const char * _s2) {
    while(load_byte(_s1) && load_byte(_s1) == load_byte(_s2)) {
        _s1++;
        _s2++;
    }
    return load_byte(_s1) - load_byte(_s2);
}

bool read_command(Command * _cmd) {
    char cmdLine[80];
    uart_getline(cmdLine, 80);
    unsigned long offset = 0;

    char cmdName[80];
    if(!get_token(cmdName, 80, cmdLine, 40, &offset)) {
        _cmd->__cmdName = NONE;
        return false;
    }

    if(strcmp(cmdName, "ri") == 0) {
        unsigned int addr, count;
        if(!get_uint32(&addr, cmdLine, 80, &offset)) {
            _cmd->__cmdName = NONE;
            return false;
        }
        if(!get_uint32_or_none(&count, cmdLine, 80, &offset)) {
            _cmd->__cmdName = NONE;
            return false;
        }
        _cmd->__cmdName = READ_INSTRUCTION;
        _cmd->__args[0] = addr;
        _cmd->__args[1] = count;
        return true;
    }
    else if(strcmp(cmdName, "wi") == 0) {
        unsigned int addr, count;
        if(!get_uint32(&addr, cmdLine, 80, &offset)) {
            _cmd->__cmdName = NONE;
            return false;
        }
        if(!get_uint32_or_none(&count, cmdLine, 80, &offset)) {
            _cmd->__cmdName = NONE;
            return false;
        }
        _cmd->__cmdName = WRITE_INSTRUCTION;
        _cmd->__args[0] = addr;
        _cmd->__args[1] = count;
        return true;
    }
    else if(strcmp(cmdName, "rd") == 0) {
        unsigned int addr, count;
        if(!get_uint32(&addr, cmdLine, 80, &offset)) {
            _cmd->__cmdName = NONE;
            return false;
        }
        if(!get_uint32_or_none(&count, cmdLine, 80, &offset)) {
            _cmd->__cmdName = NONE;
            return false;
        }
        _cmd->__cmdName = READ_DATA;
        _cmd->__args[0] = addr;
        _cmd->__args[1] = count;
        return true;
    }
    else if(strcmp(cmdName, "wd") == 0) {
        unsigned int addr, count;
        if(!get_uint32(&addr, cmdLine, 80, &offset)) {
            _cmd->__cmdName = NONE;
            return false;
        }
        if(!get_uint32_or_none(&count, cmdLine, 80, &offset)) {
            _cmd->__cmdName = NONE;
            return false;
        }
        _cmd->__cmdName = WRITE_DATA;
        _cmd->__args[0] = addr;
        _cmd->__args[1] = count;
        return true;
    }
    else if(strcmp(cmdName, "rr") == 0) {
        _cmd->__cmdName = READ_REGISTER;
        return true;
    }
    else if(strcmp(cmdName, "bs") == 0) {
        unsigned int addr;
        if(!get_uint32(&addr, cmdLine, 80, &offset)) {
            _cmd->__cmdName = NONE;
            return false;
        }
        _cmd->__cmdName = BREAKPOINT_SET;
        _cmd->__args[0] = addr;
        return true;
    }
    else if(strcmp(cmdName, "bd") == 0) {
        unsigned int id;
        if(!get_uint32(&id, cmdLine, 80, &offset)) {
            _cmd->__cmdName = NONE;
            return false;
        }
        _cmd->__cmdName = BREAKPOINT_DELETE;
        _cmd->__args[0] = id;
        return true;
    }
    else if(strcmp(cmdName, "bl") == 0) {
        _cmd->__cmdName = BREAKPOINT_LIST;
        return true;
    }
    else if(strcmp(cmdName, "step") == 0) {
        unsigned int count;
        if(!get_uint32_or_none(&count, cmdLine, 80, &offset)) {
            _cmd->__cmdName = STEP;
            _cmd->__args[0] = 1;
            return true;
        }
        _cmd->__cmdName = STEP;
        _cmd->__args[0] = count;
        return true;
    }
    else if(strcmp(cmdName, "run") == 0) {
        _cmd->__cmdName = RUN;
        return true;
    }
    else if(strcmp(cmdName, "brun") == 0) {
        // brun 直接触发硬件 RUN，由 CPU 内部计时器统计整段执行周期，避免 step 模式引入串口开销。
        _cmd->__cmdName = BENCHMARK_RUN;
        return true;
    }
    else if(strcmp(cmdName, "cycles") == 0) {
        // cycles 读取最近一次 benchmark 的 CPU 周期结果，不会重新启动程序。
        _cmd->__cmdName = BENCHMARK_CYCLES;
        return true;
    }
    else if(strcmp(cmdName, "bpd") == 0) {
        // bpd 只负责动态开关分支预测器：无参数时查询，有参数时只更新 bit0，不影响 benchmark arm/clear。
        _cmd->__cmdName = BRANCH_PREDICTOR_DISABLE;
        if(!has_more_token(cmdLine, 80, offset)) {
            _cmd->__args[0] = 0;
            _cmd->__args[1] = 0;
            return true;
        }
        unsigned int disable;
        if(!get_uint32(&disable, cmdLine, 80, &offset)) {
            _cmd->__cmdName = NONE;
            return false;
        }
        _cmd->__args[0] = 1;
        _cmd->__args[1] = disable ? 1 : 0;
        return true;
    }
    else if(strcmp(cmdName, "reset") == 0) {
        _cmd->__cmdName = RESET;
        return true;
    }
    else {
        _cmd->__cmdName = NONE;
        uart_puts("\n\rInvalid command: '");
        uart_puts(cmdName);
        uart_puts("'\n\r");
        return false;
    }
}

void execute_command(Command * _cmd) {
    switch(_cmd->__cmdName) {
    case READ_INSTRUCTION:
        return read_instruction(_cmd->__args[0], _cmd->__args[1]);
    case WRITE_INSTRUCTION:
        return write_instruction(_cmd->__args[0], _cmd->__args[1]);
    case READ_DATA:
        return read_data(_cmd->__args[0], _cmd->__args[1]);
    case WRITE_DATA:
        return write_data(_cmd->__args[0], _cmd->__args[1]);
    case READ_REGISTER:
        return read_register();
    case BREAKPOINT_SET:
        return breakpoint_set(_cmd->__args[0]);
    case BREAKPOINT_DELETE:
        return breakpoint_delete(_cmd->__args[0]);
    case BREAKPOINT_LIST:
        return breakpoint_list();
    case STEP:
        return step(_cmd->__args[0]);
    case RUN:
        return run();
    case BENCHMARK_RUN:
        return benchmark_run();
    case BENCHMARK_CYCLES:
        return benchmark_cycles();
    case BRANCH_PREDICTOR_DISABLE:
        return branch_predictor_disable(_cmd->__args[0], _cmd->__args[1]);
    case RESET:
        return reset();
    case NONE:
        return;
    }
}

void read_instruction(unsigned int _addr, unsigned int _count) {
    if(_addr & 0x3) {
        uart_puts("Address not aligned: ");
        uart_put_uint32_hex8(_addr);
        uart_puts("\n\r");
        return;
    }
    if(_addr < CORE_IMEM_START || _addr >= CORE_IMEM_END) {
        uart_puts("Address out of range: ");
        uart_put_uint32_hex8(_addr);
        uart_puts("\n\r");
        return;
    }
    for(int i = 0; i < _count && _addr + (1 << 2) < CORE_IMEM_END; i++) {
        *CORE_INST_ADDR = _addr + (i << 2);
        *CORE_COMMAND = COMMAND_READ_INSTRUCTION;
        while(*CORE_ACK == 0);
        uart_put_uint32_hex8(_addr + (i << 2));
        uart_puts(": ");
        uart_put_uint32_hex8(*CORE_INST_READ);
        uart_puts("\n\r");
        *CORE_COMMAND = COMMAND_NONE;
        while(*CORE_ACK != 0);
    }
}

void write_instruction(unsigned int _addr, unsigned int _count) {
    if(_addr & 0x3) {
        uart_puts("Address not aligned: ");
        uart_put_uint32_hex8(_addr);
        uart_puts("\n\r");
        return;
    }
    if(_addr < CORE_IMEM_START || _addr >= CORE_IMEM_END) {
        uart_puts("Address out of range: ");
        uart_put_uint32_hex8(_addr);
        uart_puts("\n\r");
        return;
    }
    for(int i = 0; i < _count && _addr + (1 << 2) < CORE_IMEM_END; i++) {
        *CORE_INST_ADDR = _addr + (i << 2);
        unsigned int _inst;
        if(!uart_get_uint32(&_inst)) {
            uart_puts("\n\rCommand aborted at ");
            uart_put_uint32_hex8(_addr + (i << 2));
            uart_puts("\n\r");
            return;
        }
        *CORE_INST_WRITE = _inst;
        *CORE_COMMAND = COMMAND_WRITE_INSTRUCTION;
        while(*CORE_ACK == 0);
        *CORE_COMMAND = COMMAND_NONE;
        while(*CORE_ACK != 0);
    }
}

void read_data(unsigned int _addr, unsigned int _count) {
    if(_addr & 0x3) {
        uart_puts("Address not aligned: ");
        uart_put_uint32_hex8(_addr);
        uart_puts("\n\r");
        return;
    }
    if(_addr < CORE_DMEM_START || _addr >= CORE_DMEM_END) {
        uart_puts("Address out of range: ");
        uart_put_uint32_hex8(_addr);
        uart_puts("\n\r");
        return;
    }
    for(int i = 0; i < _count && _addr + (1 << 2) < CORE_DMEM_END; i++) {
        *CORE_DATA_ADDR = _addr + (i << 2);
        *CORE_COMMAND = COMMAND_READ_DATA;
        while(*CORE_ACK == 0);
        uart_put_uint32_hex8(_addr + (i << 2));
        uart_puts(": ");
        uart_put_uint32_hex8(*CORE_DATA_READ);
        uart_puts("\n\r");
        *CORE_COMMAND = COMMAND_NONE;
        while(*CORE_ACK != 0);
    }
}

void write_data(unsigned int _addr, unsigned int _count) {
    if(_addr & 0x3) {
        uart_puts("Address not aligned: ");
        uart_put_uint32_hex8(_addr);
        uart_puts("\n\r");
        return;
    }
    if(_addr < CORE_DMEM_START || _addr >= CORE_DMEM_END) {
        uart_puts("Address out of range: ");
        uart_put_uint32_hex8(_addr);
        uart_puts("\n\r");
        return;
    }
    for(int i = 0; i < _count && _addr + (1 << 2) < CORE_DMEM_END; i++) {
        *CORE_DATA_ADDR = _addr + (i << 2);
        unsigned int _data;
        if(!uart_get_uint32(&_data)) {
            uart_puts("\n\rCommand aborted at ");
            uart_put_uint32_hex8(_addr + (i << 2));
            uart_puts("\n\r");
            return;
        }
        *CORE_DATA_WRITE = _data;
        *CORE_COMMAND = COMMAND_WRITE_DATA;
        while(*CORE_ACK == 0);
        *CORE_COMMAND = COMMAND_NONE;
        while(*CORE_ACK != 0);
    }
}

void read_register() {
    *CORE_COMMAND = COMMAND_READ_REGISTER;
    while(*CORE_ACK == 0);
    for(int i = 0; i < 32; i++) {
        uart_puts("Register ");
        uart_put_uint32_hex(i);
        uart_puts(": ");
        uart_put_uint32_hex8(*(CORE_REG0 + i));
        uart_puts("\n\r");
    }
    *CORE_COMMAND = COMMAND_NONE;
    while(*CORE_ACK != 0);
}

void breakpoint_set(unsigned int _addr) {
    if(_addr & 0x3) {
        uart_puts("Address not aligned: ");
        uart_put_uint32_hex8(_addr);
        uart_puts("\n\r");
        return;
    }
    if(_addr < CORE_IMEM_START || _addr >= CORE_IMEM_END) {
        uart_puts("Address out of range: ");
        uart_put_uint32_hex8(_addr);
        uart_puts("\n\r");
        return;
    }
    *CORE_NEW_BREAKPOINT_ADDR = _addr;
    *CORE_COMMAND = COMMAND_BREAKPOINT_SET;
    while(*CORE_ACK == 0);
    if(*CORE_BREAKPOINT_SET == 1) {
        uart_puts("Breakpoint ");
        uart_put_uint32_hex(*CORE_NEW_BREAKPOINT_ID);
        uart_puts(" set at ");
        uart_put_uint32_hex8(*(CORE_BREAKPOINT_ADDR0 + *CORE_NEW_BREAKPOINT_ID));
        uart_puts("\n\r");
    }
    else {
        uart_puts("Breakpoint not set\n");
    }
    *CORE_COMMAND = COMMAND_NONE;
    while(*CORE_ACK != 0);
}

void breakpoint_delete(unsigned int _id) {
    *CORE_DELETE_BREAKPOINT_ID = _id;
    *CORE_COMMAND = COMMAND_BREAKPOINT_DELETE;
    while(*CORE_ACK == 0);
    if(*CORE_BREAKPOINT_DELETED == 1) {
        uart_puts("Breakpoint ");
        uart_put_uint32_hex(_id);
        uart_puts(" deleted at ");
        uart_put_uint32_hex8(*CORE_DELETE_BREAKPOINT_ADDR);
        uart_puts("\n\r");
    }
    else {
        uart_puts("Breakpoint ");
        uart_put_uint32_hex(_id);
        uart_puts(" not found\n");
    }
    *CORE_COMMAND = COMMAND_NONE;
    while(*CORE_ACK != 0);
}

void breakpoint_list() {
    *CORE_COMMAND = COMMAND_BREAKPOINT_LIST;
    while(*CORE_ACK == 0);
    for(int i = 0; i < 8; i++) {
        if(*CORE_BREAKPOINT_IDS & (1 << i)) {
            uart_puts("Breakpoint ");
            uart_put_uint32_hex(i);
            uart_puts(" at ");
            uart_put_uint32_hex8(*(CORE_BREAKPOINT_ADDR0 + i));
            uart_puts("\n\r");
        }
    }
    *CORE_COMMAND = COMMAND_NONE;
    while(*CORE_ACK != 0);
}

static bool step1() {
    *CORE_COMMAND = COMMAND_STEP;
    while(*CORE_ACK == 0);
    if(*CORE_BREAK == 8) {
        uart_puts("Halted at ");
        uart_put_uint32_hex8(*CORE_CURRENT_PC);
        uart_puts("\n\r");
        *CORE_COMMAND = COMMAND_NONE;
        while(*CORE_ACK != 0);
        return false;
    }
    if(*CORE_BREAK != 0) {
        uart_puts("Breakpoint ");
        uart_put_uint32_hex(*CORE_BREAK);
        uart_puts(" hit at ");
        uart_put_uint32_hex8(*CORE_CURRENT_PC);
        uart_puts("\n\r");
        *CORE_COMMAND = COMMAND_NONE;
        while(*CORE_ACK != 0);
        return false;
    }
    *CORE_COMMAND = COMMAND_NONE;
    while(*CORE_ACK != 0);
    return true;
}

void step(unsigned int _count) {
    for(unsigned int i = 0; i < _count && step1(); i++);
    uart_puts("Current PC: ");
    uart_put_uint32_hex8(*CORE_CURRENT_PC);
    uart_puts("\n\r");
}

void run() {
    while(step1());
}

void benchmark_run() {
    unsigned int predictor_disable = *CORE_BENCH_CTRL & 0x1;

    // 基准测试必须走硬件 RUN，而不是循环 step1()；
    // 否则每条指令之间都会夹入 PDU 串口和 ACK 开销，周期数无法反映 CPU 本身性能。
    *CORE_BENCH_CTRL = predictor_disable | (1 << 2);
    while(*CORE_BENCH_CTRL & (1 << 2));

    *CORE_BENCH_CTRL = predictor_disable | (1 << 1);
    *CORE_COMMAND = COMMAND_RUN;
    while(*CORE_ACK == 0);

    if(*CORE_BREAK == 8) {
        uart_puts("Halted at ");
        uart_put_uint32_hex8(*CORE_CURRENT_PC);
        uart_puts("\n\r");
    }
    else {
        uart_puts("Breakpoint ");
        uart_put_uint32_hex(*CORE_BREAK);
        uart_puts(" hit at ");
        uart_put_uint32_hex8(*CORE_CURRENT_PC);
        uart_puts("\n\r");
    }

    if(*CORE_BENCH_CTRL & (1 << 8)) {
        uart_puts("Benchmark cycles: ");
        uart_put_uint32_hex8(*CORE_BENCH_CYCLES);
        uart_puts("\n\r");
    }
    else {
        uart_puts("Benchmark did not finish at EBREAK; cycle result is not valid\n\r");
    }

    *CORE_COMMAND = COMMAND_NONE;
    while(*CORE_ACK != 0);
    *CORE_BENCH_CTRL = predictor_disable;
}

void benchmark_cycles() {
    uart_puts("Benchmark cycles: ");
    uart_put_uint32_hex8(*CORE_BENCH_CYCLES);
    uart_puts("\n\r");
}

void branch_predictor_disable(unsigned int _has_arg, unsigned int _disable) {
    unsigned int ctrl = *CORE_BENCH_CTRL;

    if(_has_arg) {
        // 只修改 bit0，保留 benchmark 状态位的硬件只读语义，不主动触发 arm/clear。
        if(_disable) {
            ctrl |= 1;
        }
        else {
            ctrl &= ~1;
        }
        *CORE_BENCH_CTRL = ctrl;
    }

    uart_puts("Branch predictor: ");
    if(*CORE_BENCH_CTRL & 1) {
        uart_puts("disabled\n\r");
    }
    else {
        uart_puts("enabled\n\r");
    }
}

void reset() {
    *CORE_COMMAND = COMMAND_RESET;
    while(*CORE_ACK == 0);
    uart_puts("Core reset\n\r");
    *CORE_COMMAND = COMMAND_NONE;
    while(*CORE_ACK != 0);
}
