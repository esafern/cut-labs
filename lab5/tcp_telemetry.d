#!/usr/sbin/dtrace -s

#pragma D option quiet

dtrace:::BEGIN
{
    printf("%-20s %-6s %-16s %-6s %-6s %s\n",
        "TIMESTAMP", "PID", "PROCESS", "EVENT", "FD", "DETAILS");
    printf("%-20s %-6s %-16s %-6s %-6s %s\n",
        "--------------------", "------", "----------------",
        "------", "------", "-------");
}

syscall::socket:entry
{
    self->domain = arg0;
    self->type = arg1;
}

syscall::socket:return
/arg1 >= 0/
{
    printf("%-20Y %-6d %-16s %-6s %-6d domain=%d type=%d\n",
        walltimestamp, pid, execname, "SOCK", (int)arg1,
        (int)self->domain, (int)self->type);
}

syscall::connect:entry
{
    self->connfd = arg0;
}

syscall::connect:return
/arg1 == 0/
{
    printf("%-20Y %-6d %-16s %-6s %-6d status=OK\n",
        walltimestamp, pid, execname, "CONN", (int)self->connfd);
}

syscall::connect:return
/arg1 != 0/
{
    printf("%-20Y %-6d %-16s %-6s %-6d status=ERR(%d)\n",
        walltimestamp, pid, execname, "CONN", (int)self->connfd, errno);
}

syscall::write:entry
/arg0 > 2/
{
    self->writefd = arg0;
    self->writelen = arg2;
}

syscall::write:return
/self->writelen > 0 && arg1 > 0/
{
    printf("%-20Y %-6d %-16s %-6s %-6d bytes=%d\n",
        walltimestamp, pid, execname, "SEND", (int)self->writefd,
        (int)arg1);
    self->writelen = 0;
}

syscall::read:return
/arg1 > 0 && arg0 > 2/
{
    printf("%-20Y %-6d %-16s %-6s %-6d bytes=%d\n",
        walltimestamp, pid, execname, "RECV", (int)arg0, (int)arg1);
}
