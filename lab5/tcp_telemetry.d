#!/usr/sbin/dtrace -s

/*
 * CUT Agent — Ambient Factor Collector
 * Patent ref: US 12,309,132 B1, FIG.1 element 104
 *
 * Traces network-related syscalls system-wide.
 * Works under macOS SIP (syscall provider only).
 *
 * Usage:
 *   sudo dtrace -s tcp_telemetry.d > dtrace.out
 *   sudo dtrace -s tcp_telemetry.d -p <PID>    (filter to one process)
 *
 * Output: one line per event, parseable by transform_ambient.py
 */

#pragma D option quiet

dtrace:::BEGIN
{
    printf("%-24s %-6s %-20s %-4s %-4s %s\n",
        "TIMESTAMP", "PID", "PROCESS", "EVT", "FD", "DETAILS");
}

syscall::socket:entry
{
    self->sock_domain = arg0;
    self->sock_type = arg1;
}

syscall::socket:return
/arg1 >= 0/
{
    printf("%Y PID=%-6d PROC=%-20s SOCK fd=%d domain=%d type=%d\n",
        walltimestamp, pid, execname, (int)arg1,
        self->sock_domain, self->sock_type);
}

syscall::connect:entry
{
    printf("%Y PID=%-6d PROC=%-20s CONN fd=%d\n",
        walltimestamp, pid, execname, arg0);
}

syscall::write:entry
/arg0 > 2/
{
    printf("%Y PID=%-6d PROC=%-20s SEND fd=%d bytes=%d\n",
        walltimestamp, pid, execname, arg0, arg2);
}

syscall::read:entry
/arg0 > 2/
{
    printf("%Y PID=%-6d PROC=%-20s RECV fd=%d bytes=%d\n",
        walltimestamp, pid, execname, arg0, arg2);
}

syscall::close:entry
/arg0 > 2/
{
    printf("%Y PID=%-6d PROC=%-20s CLOS fd=%d\n",
        walltimestamp, pid, execname, arg0);
}
