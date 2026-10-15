# tism — POSIX time(1) for x86-64 Linux, in pure assembly.
#
# Build: make
#   tism [-p] utility [argument...]
#
# No libc. The process image talks to the kernel with the syscall instruction.
# x86-64 syscall ABI: rax = number, rdi rsi rdx r10 r8 r9 = args
# (the fourth argument is r10, because syscall clobbers rcx and r11).
# Return is in rax; errors are the negative errno.
#
# Wall time is CLOCK_MONOTONIC around the child. User and system time come
# from wait4's rusage, which is the child plus descendants it has waited for
# (POSIX tms_utime+tms_cutime and tms_stime+tms_cstime).
#
# A pipe created with O_CLOEXEC carries exec failure back to the parent.
# Successful exec closes the write end, so the parent reads EOF. A failed
# exec writes the errno and exits. That distinguishes "utility exited 127"
# from "utility was not found".

.equ SYS_read,           0
.equ SYS_write,          1
.equ SYS_close,          3
.equ SYS_pipe2,          293
.equ SYS_fork,           57
.equ SYS_execve,         59
.equ SYS_exit,           60
.equ SYS_wait4,          61
.equ SYS_clock_gettime,  228
.equ SYS_newfstatat,     262

.equ CLOCK_MONOTONIC,    1
.equ O_CLOEXEC,          0x80000

.equ EPERM,              1
.equ ENOENT,             2
.equ EINTR,              4
.equ EIO,                5
.equ E2BIG,              7
.equ ENOEXEC,            8
.equ ENOMEM,             12
.equ EACCES,             13
.equ EFAULT,             14
.equ ENOTDIR,            20
.equ EISDIR,             21
.equ EINVAL,             22
.equ ENFILE,             23
.equ EMFILE,             24
.equ ETXTBSY,            26
.equ ENAMETOOLONG,       36
.equ ELOOP,              40

.equ AT_FDCWD,           -100
.equ S_IFMT,             0xf000
.equ S_IFDIR,            0x4000

.equ PATH_MAX,           4096

.section .bss
.align 8
pipefd:     .space 8            # int[2]: read, write
child_pid:  .space 8
envp_ptr:   .space 8
argv_ptr:   .space 8            # utility's argv, already NULL-terminated
name_ptr:   .space 8
real_sec:   .space 8
real_nsec:  .space 8
start_ts:   .space 16           # struct timespec
end_ts:     .space 16
ru:         .space 144          # struct rusage; utime at 0, stime at 16
pathbuf:    .space PATH_MAX
outbuf:     .space 256

.align 4
exec_errno: .space 4
status:     .space 4
exit_code:  .space 4
posix_fmt:  .space 1

.section .rodata, "a"

.Lusage_msg:
	.ascii "usage: tism [-p] utility [argument...]\n"
	.byte 0
.Lmissing_msg:
	.ascii "tism: missing operand\n"
	.byte 0
.Linvalid_msg:
	.ascii "tism: invalid option: "
	.byte 0
.Lpref:
	.ascii "tism: "
	.byte 0
.Lcolon:
	.ascii ": "
	.byte 0
.Lnl:
	.ascii "\n"
	.byte 0
.Lerr_clock:
	.ascii "tism: clock_gettime failed\n"
	.byte 0
.Lerr_pipe:
	.ascii "tism: pipe failed\n"
	.byte 0
.Lerr_fork:
	.ascii "tism: fork failed\n"
	.byte 0
.Lerr_wait:
	.ascii "tism: wait failed\n"
	.byte 0
.Ldefpath:
	.ascii "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
	.byte 0
.Lpathkey:
	.ascii "PATH="
	.byte 0
.Lunknown:
	.ascii "Cannot execute command"
	.byte 0

.Lreal_tab: .ascii "real\t"
	.set REAL_TAB_LEN, . - .Lreal_tab
.Luser_tab: .ascii "user\t"
	.set USER_TAB_LEN, . - .Luser_tab
.Lsys_tab:  .ascii "sys\t"
	.set SYS_TAB_LEN, . - .Lsys_tab
.Lreal_sp:  .ascii "real "
	.set REAL_SP_LEN, . - .Lreal_sp
.Luser_sp:  .ascii "user "
	.set USER_SP_LEN, . - .Luser_sp
.Lsys_sp:   .ascii "sys "
	.set SYS_SP_LEN, . - .Lsys_sp

.Lm_eperm:    .ascii "Operation not permitted\0"
.Lm_enoent:   .ascii "No such file or directory\0"
.Lm_eio:      .ascii "Input/output error\0"
.Lm_e2big:    .ascii "Argument list too long\0"
.Lm_enoexec:  .ascii "Exec format error\0"
.Lm_enomem:   .ascii "Cannot allocate memory\0"
.Lm_eacces:   .ascii "Permission denied\0"
.Lm_efault:   .ascii "Bad address\0"
.Lm_enotdir:  .ascii "Not a directory\0"
.Lm_eisdir:   .ascii "Is a directory\0"
.Lm_einval:   .ascii "Invalid argument\0"
.Lm_enfile:   .ascii "Too many open files in system\0"
.Lm_emfile:   .ascii "Too many open files\0"
.Lm_etxtbsy:  .ascii "Text file busy\0"
.Lm_enametoolong: .ascii "File name too long\0"
.Lm_eloop:    .ascii "Too many levels of symbolic links\0"

.section .text
.globl _start

# ---------------------------------------------------------------------------
# Entry. Kernel stack: argc, argv pointers, NULL, envp pointers, NULL, auxv.
# rsp is 16-byte aligned. DF is left clear for the string moves below.
_start:
	cld
	mov	(%rsp), %r12                    # argc
	lea	8(%rsp), %r13                   # argv
	lea	8(%r13, %r12, 8), %rax          # envp
	mov	%rax, envp_ptr(%rip)

	mov	$1, %r14                        # argv index
.Largs:
	cmp	%r12, %r14
	jge	.Lmissing
	mov	(%r13, %r14, 8), %rbx
	cmpb	$'-', (%rbx)
	jne	.Lutility
	cmpb	$'-', 1(%rbx)
	je	.Lddash
	cmpb	$'p', 1(%rbx)
	jne	.Lbadopt
	cmpb	$0, 2(%rbx)
	jne	.Lbadopt
	movb	$1, posix_fmt(%rip)
	inc	%r14
	jmp	.Largs
.Lddash:
	cmpb	$0, 2(%rbx)
	jne	.Lbadopt
	inc	%r14
	cmp	%r12, %r14
	jge	.Lmissing
	mov	(%r13, %r14, 8), %rbx
.Lutility:
	lea	(%r13, %r14, 8), %rax
	mov	%rax, argv_ptr(%rip)
	mov	%rbx, name_ptr(%rip)
	jmp	.Llaunch

.Lbadopt:
	lea	.Linvalid_msg(%rip), %rdi
	call	write_cstr
	mov	%rbx, %rdi
	call	write_cstr
	lea	.Lnl(%rip), %rdi
	call	write_cstr
	jmp	.Lusage
.Lmissing:
	lea	.Lmissing_msg(%rip), %rdi
	call	write_cstr
.Lusage:
	lea	.Lusage_msg(%rip), %rdi
	call	write_cstr
	mov	$1, %edi
	jmp	sys_exit

.Llaunch:
	mov	$CLOCK_MONOTONIC, %edi
	lea	start_ts(%rip), %rsi
	mov	$SYS_clock_gettime, %eax
	syscall
	test	%rax, %rax
	js	.Lclock_fail

	lea	pipefd(%rip), %rdi
	mov	$O_CLOEXEC, %esi
	mov	$SYS_pipe2, %eax
	syscall
	test	%rax, %rax
	js	.Lpipe_fail

	mov	$SYS_fork, %eax
	syscall
	test	%rax, %rax
	jz	.Lchild
	js	.Lfork_fail

	mov	%rax, child_pid(%rip)
	movl	pipefd+4(%rip), %edi
	mov	$SYS_close, %eax
	syscall

	# Zero rusage so a short wait cannot leak stack garbage into the report.
	lea	ru(%rip), %rdi
	mov	$18, %ecx
	xor	%eax, %eax
	rep	stosq

.Lwait:
	mov	child_pid(%rip), %rdi
	lea	status(%rip), %rsi
	xor	%edx, %edx
	lea	ru(%rip), %r10
	mov	$SYS_wait4, %eax
	syscall
	cmp	$-EINTR, %rax
	je	.Lwait
	test	%rax, %rax
	js	.Lwait_fail
	# options is 0, so a stopped child is not reported. If one shows up, keep waiting.
	movl	status(%rip), %eax
	and	$0x7f, %eax
	cmp	$0x7f, %eax
	je	.Lwait

	mov	$CLOCK_MONOTONIC, %edi
	lea	end_ts(%rip), %rsi
	mov	$SYS_clock_gettime, %eax
	syscall
	test	%rax, %rax
	js	.Lclock_fail

	call	read_exec_errno
	call	decode_status
	movl	%eax, exit_code(%rip)

	cmpl	$0, exec_errno(%rip)
	je	.Lreport
	call	print_exec_error
	# ENOENT is "not found" (127). Every other exec errno, including
	# ENOTDIR and EACCES, means the name was resolved but could not run (126).
	mov	$126, %eax
	cmpl	$ENOENT, exec_errno(%rip)
	jne	.Lstore_fail
	mov	$127, %eax
.Lstore_fail:
	movl	%eax, exit_code(%rip)

.Lreport:
	call	print_report
	movl	exit_code(%rip), %edi
	jmp	sys_exit

.Lclock_fail:
	lea	.Lerr_clock(%rip), %rdi
	call	write_cstr
	mov	$1, %edi
	jmp	sys_exit
.Lpipe_fail:
	lea	.Lerr_pipe(%rip), %rdi
	call	write_cstr
	mov	$1, %edi
	jmp	sys_exit
.Lfork_fail:
	lea	.Lerr_fork(%rip), %rdi
	call	write_cstr
	mov	$1, %edi
	jmp	sys_exit
.Lwait_fail:
	lea	.Lerr_wait(%rip), %rdi
	call	write_cstr
	mov	$1, %edi
	jmp	sys_exit

# Child. Registers and memory match the parent at the fork.
# Close the read end, exec, and on failure send errno down the write end.
.Lchild:
	movl	pipefd(%rip), %edi
	mov	$SYS_close, %eax
	syscall
	call	do_exec
	movl	%eax, exec_errno(%rip)
	mov	$126, %edi
	cmpl	$ENOENT, %eax
	jne	.Lchild_write
	mov	$127, %edi
.Lchild_write:
	push	%rdi
	movl	pipefd+4(%rip), %edi
	lea	exec_errno(%rip), %rsi
	mov	$4, %edx
	mov	$SYS_write, %eax
	syscall
	pop	%rdi
	jmp	sys_exit

# ---------------------------------------------------------------------------
# do_exec: exec name_ptr with argv_ptr and envp_ptr.
# Returns positive errno in eax. Does not return on success.
do_exec:
	push	%rbp
	push	%r12
	push	%r13
	push	%r14
	push	%r15
	mov	name_ptr(%rip), %r12
	cmpb	$0, (%r12)
	jne	.Lhave_name
	mov	$ENOENT, %eax
	jmp	.Lfail_ret
.Lhave_name:
	mov	%r12, %rsi
.Lscan:
	movb	(%rsi), %al
	test	%al, %al
	jz	.Lsearch
	cmp	$'/', %al
	je	.Ldirect
	inc	%rsi
	jmp	.Lscan
.Ldirect:
	mov	%r12, %rdi
	mov	argv_ptr(%rip), %rsi
	mov	envp_ptr(%rip), %rdx
	mov	$SYS_execve, %eax
	syscall
	neg	%eax
	jmp	.Lfail_ret

.Lsearch:
	call	find_path
	mov	%rax, %r13              # PATH cursor
	xor	%ebp, %ebp              # seen EACCES
.Lcomp:
	# Copy one PATH component into pathbuf. Empty component means ".".
	lea	pathbuf(%rip), %rdi
	mov	%r13, %rsi
	xor	%r14, %r14
.Lcopydir:
	movb	(%rsi), %al
	test	%al, %al
	jz	.Ldirdone
	cmp	$':', %al
	je	.Ldirdone
	cmp	$PATH_MAX-1, %r14
	jae	.Ltoolong
	mov	%al, (%rdi)
	inc	%rdi
	inc	%rsi
	inc	%r14
	jmp	.Lcopydir
.Ldirdone:
	mov	%rsi, %r15              # points at ':' or NUL; survives execve
	test	%r14, %r14
	jnz	.Lnotempty
	movb	$'.', (%rdi)
	inc	%rdi
	inc	%r14
.Lnotempty:
	cmpb	$'/', -1(%rdi)
	je	.Lcopyname_start
	cmp	$PATH_MAX-1, %r14
	jae	.Ltoolong
	movb	$'/', (%rdi)
	inc	%rdi
	inc	%r14
.Lcopyname_start:
	mov	%r12, %rcx
.Lcopyname:
	movb	(%rcx), %al
	cmp	$PATH_MAX-1, %r14
	jae	.Ltoolong
	mov	%al, (%rdi)
	inc	%rdi
	inc	%rcx
	inc	%r14
	test	%al, %al
	jnz	.Lcopyname

	lea	pathbuf(%rip), %rdi
	mov	argv_ptr(%rip), %rsi
	mov	envp_ptr(%rip), %rdx
	mov	$SYS_execve, %eax
	syscall
	neg	%eax
	cmp	$EACCES, %eax
	je	.Lseen_eacces
	cmp	$ENOENT, %eax
	je	.Lnextc
	cmp	$ENOTDIR, %eax
	je	.Lnextc
	jmp	.Lfail_ret
.Lseen_eacces:
	mov	$1, %ebp
.Lnextc:
	cmpb	$0, (%r15)
	je	.Lsearch_done
	inc	%r15                    # skip ':'
	mov	%r15, %r13
	jmp	.Lcomp
.Lsearch_done:
	mov	$ENOENT, %eax
	test	%ebp, %ebp
	jz	.Lfail_ret
	mov	$EACCES, %eax
	jmp	.Lfail_ret
.Ltoolong:
	mov	$ENAMETOOLONG, %eax
.Lfail_ret:
	pop	%r15
	pop	%r14
	pop	%r13
	pop	%r12
	pop	%rbp
	ret

# rax = value of PATH, or the built-in default. Byte-wise compare so a short
# env string cannot run off its terminating NUL.
find_path:
	mov	envp_ptr(%rip), %rsi
.Lenv:
	mov	(%rsi), %rdi
	test	%rdi, %rdi
	jz	.Ldefault
	lea	.Lpathkey(%rip), %rax
	mov	%rdi, %rcx
.Lcmpkey:
	movb	(%rax), %dl
	test	%dl, %dl
	jz	.Lkey_ok
	cmpb	%dl, (%rcx)
	jne	.Lnextenv
	inc	%rax
	inc	%rcx
	jmp	.Lcmpkey
.Lkey_ok:
	mov	%rcx, %rax
	ret
.Lnextenv:
	add	$8, %rsi
	jmp	.Lenv
.Ldefault:
	lea	.Ldefpath(%rip), %rax
	ret

# ---------------------------------------------------------------------------
# After wait4: EOF means exec worked. Four bytes are the child's errno.
read_exec_errno:
	movl	$0, exec_errno(%rip)
.Lrd:
	movl	pipefd(%rip), %edi
	lea	exec_errno(%rip), %rsi
	mov	$4, %edx
	xor	%eax, %eax
	syscall
	cmp	$-EINTR, %rax
	je	.Lrd
	cmp	$4, %rax
	je	.Lrd_done
	movl	$0, exec_errno(%rip)
.Lrd_done:
	ret

# eax = exit status. Signal death becomes 128+signal, matching the shell.
decode_status:
	movl	status(%rip), %eax
	mov	%eax, %ecx
	and	$0x7f, %ecx
	jz	.Lexited
	lea	128(%ecx), %eax
	ret
.Lexited:
	movl	status(%rip), %eax
	shr	$8, %eax
	and	$0xff, %eax
	ret

print_exec_error:
	lea	.Lpref(%rip), %rdi
	call	write_cstr
	mov	name_ptr(%rip), %rdi
	call	write_cstr
	lea	.Lcolon(%rip), %rdi
	call	write_cstr
	# execve(directory) fails with EACCES on Linux. Say so when the
	# operand itself is a directory; a PATH search still reports EACCES.
	cmpl	$EACCES, exec_errno(%rip)
	jne	.Lerrno_text
	call	path_is_dir
	test	%eax, %eax
	jz	.Lerrno_text
	lea	.Lm_eisdir(%rip), %rax
	jmp	.Lwrite_errno
.Lerrno_text:
	movl	exec_errno(%rip), %eax
	call	errno_msg
.Lwrite_errno:
	mov	%rax, %rdi
	call	write_cstr
	lea	.Lnl(%rip), %rdi
	call	write_cstr
	ret

# eax = 1 when name_ptr contains a slash and names a directory.
# Kernel struct stat: st_mode is a 32-bit field at offset 24.
path_is_dir:
	mov	name_ptr(%rip), %rsi
.Lfind_slash:
	movb	(%rsi), %al
	test	%al, %al
	jz	.Lnot_dir
	cmp	$'/', %al
	je	.Lstat_dir
	inc	%rsi
	jmp	.Lfind_slash
.Lstat_dir:
	sub	$160, %rsp
	mov	$AT_FDCWD, %rdi
	mov	name_ptr(%rip), %rsi
	mov	%rsp, %rdx
	xor	%r10d, %r10d
	mov	$SYS_newfstatat, %eax
	syscall
	test	%rax, %rax
	js	.Lstat_no
	movl	24(%rsp), %eax
	and	$S_IFMT, %eax
	cmp	$S_IFDIR, %eax
	jne	.Lstat_no
	add	$160, %rsp
	mov	$1, %eax
	ret
.Lstat_no:
	add	$160, %rsp
.Lnot_dir:
	xor	%eax, %eax
	ret

errno_msg:
	cmp	$EPERM, %eax
	je	.Leperm
	cmp	$ENOENT, %eax
	je	.Lenoent
	cmp	$EIO, %eax
	je	.Leio
	cmp	$E2BIG, %eax
	je	.Le2big
	cmp	$ENOEXEC, %eax
	je	.Lenoexec
	cmp	$ENOMEM, %eax
	je	.Lenomem
	cmp	$EACCES, %eax
	je	.Leacces
	cmp	$EFAULT, %eax
	je	.Lefault
	cmp	$ENOTDIR, %eax
	je	.Lenotdir
	cmp	$EISDIR, %eax
	je	.Leisdir
	cmp	$EINVAL, %eax
	je	.Leinval
	cmp	$ENFILE, %eax
	je	.Lenfile
	cmp	$EMFILE, %eax
	je	.Lemfile
	cmp	$ETXTBSY, %eax
	je	.Letxtbsy
	cmp	$ENAMETOOLONG, %eax
	je	.Lenametoolong
	cmp	$ELOOP, %eax
	je	.Leloop
	lea	.Lunknown(%rip), %rax
	ret
.Leperm:        lea .Lm_eperm(%rip), %rax
	ret
.Lenoent:       lea .Lm_enoent(%rip), %rax
	ret
.Leio:          lea .Lm_eio(%rip), %rax
	ret
.Le2big:        lea .Lm_e2big(%rip), %rax
	ret
.Lenoexec:      lea .Lm_enoexec(%rip), %rax
	ret
.Lenomem:       lea .Lm_enomem(%rip), %rax
	ret
.Leacces:       lea .Lm_eacces(%rip), %rax
	ret
.Lefault:       lea .Lm_efault(%rip), %rax
	ret
.Lenotdir:      lea .Lm_enotdir(%rip), %rax
	ret
.Leisdir:       lea .Lm_eisdir(%rip), %rax
	ret
.Leinval:       lea .Lm_einval(%rip), %rax
	ret
.Lenfile:       lea .Lm_enfile(%rip), %rax
	ret
.Lemfile:       lea .Lm_emfile(%rip), %rax
	ret
.Letxtbsy:      lea .Lm_etxtbsy(%rip), %rax
	ret
.Lenametoolong: lea .Lm_enametoolong(%rip), %rax
	ret
.Leloop:        lea .Lm_eloop(%rip), %rax
	ret

# ---------------------------------------------------------------------------
# Report. Default format matches the traditional shell rendering:
#   real    0m0.012s
#   user    0m0.001s
#   sys     0m0.000s
# -p selects the POSIX format "real %f\nuser %f\nsys %f\n" with two decimals,
# enough for a 100 Hz clock tick and at least one digit after the radix.
print_report:
	push	%rbx
	push	%rbp
	push	%r12
	push	%r13
	push	%r14
	push	%r15
	call	compute_real
	lea	outbuf(%rip), %rbx
	cmpb	$0, posix_fmt(%rip)
	jne	.Lposix

	mov	real_sec(%rip), %r12
	mov	real_nsec(%rip), %r13
	mov	$1, %r14
	lea	.Lreal_tab(%rip), %rsi
	mov	$REAL_TAB_LEN, %r15
	call	emit_bash_line
	mov	ru(%rip), %r12
	mov	ru+8(%rip), %r13
	xor	%r14, %r14
	lea	.Luser_tab(%rip), %rsi
	mov	$USER_TAB_LEN, %r15
	call	emit_bash_line
	mov	ru+16(%rip), %r12
	mov	ru+24(%rip), %r13
	xor	%r14, %r14
	lea	.Lsys_tab(%rip), %rsi
	mov	$SYS_TAB_LEN, %r15
	call	emit_bash_line
	jmp	.Lwrite_out

.Lposix:
	mov	real_sec(%rip), %r12
	mov	real_nsec(%rip), %r13
	mov	$1, %r14
	lea	.Lreal_sp(%rip), %rsi
	mov	$REAL_SP_LEN, %r15
	call	emit_posix_line
	mov	ru(%rip), %r12
	mov	ru+8(%rip), %r13
	xor	%r14, %r14
	lea	.Luser_sp(%rip), %rsi
	mov	$USER_SP_LEN, %r15
	call	emit_posix_line
	mov	ru+16(%rip), %r12
	mov	ru+24(%rip), %r13
	xor	%r14, %r14
	lea	.Lsys_sp(%rip), %rsi
	mov	$SYS_SP_LEN, %r15
	call	emit_posix_line

.Lwrite_out:
	lea	outbuf(%rip), %rsi
	mov	%rbx, %rdx
	sub	%rsi, %rdx
	mov	$2, %edi
	call	write_full
	pop	%r15
	pop	%r14
	pop	%r13
	pop	%r12
	pop	%rbp
	pop	%rbx
	ret

# end - start, borrowing a second when nsec underflows. Negative results
# (clock stepping backwards) are reported as zero.
compute_real:
	mov	end_ts(%rip), %rax
	sub	start_ts(%rip), %rax
	mov	end_ts+8(%rip), %rcx
	sub	start_ts+8(%rip), %rcx
	jns	.Lreal_sign
	add	$1000000000, %rcx
	dec	%rax
.Lreal_sign:
	test	%rax, %rax
	jns	.Lreal_store
	xor	%eax, %eax
	xor	%ecx, %ecx
.Lreal_store:
	mov	%rax, real_sec(%rip)
	mov	%rcx, real_nsec(%rip)
	ret

# emit_bash_line
#   rbx cursor (updated)
#   r12 seconds, r13 fraction, r14 scale (0 = usec, 1 = nsec)
#   rsi label, r15 label length
emit_bash_line:
	mov	%r12, %rax
	mov	%r13, %rcx
	mov	%r14, %rdx
	call	frac_to_parts
	mov	%rax, %r12              # minutes
	mov	%rdx, %r13              # seconds within the minute
	mov	%rcx, %r14              # milliseconds
	mov	%rbx, %rdi
	mov	%r15, %rcx
	call	append_bytes
	mov	%r12, %rax
	call	format_u64
	movb	$'m', (%rdi)
	inc	%rdi
	mov	%r13, %rax
	call	format_u64
	movb	$'.', (%rdi)
	inc	%rdi
	mov	%r14, %rax
	call	append_3dig
	movb	$'s', (%rdi)
	inc	%rdi
	movb	$'\n', (%rdi)
	inc	%rdi
	mov	%rdi, %rbx
	ret

emit_posix_line:
	mov	%r12, %rax
	mov	%r13, %rcx
	mov	%r14, %rdx
	call	frac_to_posix
	mov	%rax, %r12              # whole seconds
	mov	%rdx, %r13              # hundredths
	mov	%rbx, %rdi
	mov	%r15, %rcx
	call	append_bytes
	mov	%r12, %rax
	call	format_u64
	movb	$'.', (%rdi)
	inc	%rdi
	mov	%r13, %rax
	call	append_2dig
	movb	$'\n', (%rdi)
	inc	%rdi
	mov	%rdi, %rbx
	ret

# frac_to_parts: rax=sec, rcx=fraction, rdx=scale.
# Rounds half up. Returns rax=minutes, rdx=seconds (0-59), rcx=millis.
frac_to_parts:
	mov	%rax, %r10
	mov	%rcx, %rax
	test	%rdx, %rdx
	jnz	.Lparts_nsec
	add	$500, %rax
	mov	$1000, %ecx
	jmp	.Lparts_div
.Lparts_nsec:
	add	$500000, %rax
	mov	$1000000, %ecx
.Lparts_div:
	xor	%edx, %edx
	div	%rcx                    # rax = rounded milliseconds
	xor	%edx, %edx
	mov	$1000, %ecx
	div	%rcx                    # rax = extra seconds, rdx = millis
	add	%rax, %r10
	mov	%rdx, %r11
	mov	%r10, %rax
	xor	%edx, %edx
	mov	$60, %ecx
	div	%rcx                    # rax = minutes, rdx = seconds
	mov	%r11, %rcx
	ret

# frac_to_posix: same inputs. Returns rax=seconds, rdx=hundredths.
frac_to_posix:
	mov	%rax, %r10
	mov	%rcx, %rax
	test	%rdx, %rdx
	jnz	.Lposix_nsec
	add	$5000, %rax
	mov	$10000, %ecx
	jmp	.Lposix_div
.Lposix_nsec:
	add	$5000000, %rax
	mov	$10000000, %ecx
.Lposix_div:
	xor	%edx, %edx
	div	%rcx                    # rax = rounded hundredths
	xor	%edx, %edx
	mov	$100, %ecx
	div	%rcx                    # rax = extra seconds, rdx = hundredths
	add	%rax, %r10
	mov	%r10, %rax
	ret

# format_u64: write unsigned rax as decimal at rdi. rdi advances.
# 20 digits fit in the 32-byte scratch slot.
format_u64:
	sub	$32, %rsp
	lea	32(%rsp), %rsi
	mov	%rsi, %rcx
.Ldigit:
	xor	%edx, %edx
	mov	$10, %r9
	div	%r9
	add	$'0', %dl
	dec	%rsi
	mov	%dl, (%rsi)
	test	%rax, %rax
	jnz	.Ldigit
.Ldigit_copy:
	cmp	%rsi, %rcx
	je	.Ldigit_done
	mov	(%rsi), %al
	mov	%al, (%rdi)
	inc	%rsi
	inc	%rdi
	jmp	.Ldigit_copy
.Ldigit_done:
	add	$32, %rsp
	ret

# append_3dig / append_2dig: zero-padded, rax = value, rdi = dest.
append_3dig:
	mov	$100, %r8
	xor	%edx, %edx
	div	%r8
	add	$'0', %al
	stosb
	mov	%rdx, %rax
append_2dig:
	mov	$10, %r8
	xor	%edx, %edx
	div	%r8
	add	$'0', %al
	stosb
	add	$'0', %dl
	mov	%dl, (%rdi)
	inc	%rdi
	ret

# append_bytes: copy rcx bytes from rsi to rdi. rdi advances. rcx may be 0.
append_bytes:
	cld
	rep	movsb
	ret

# ---------------------------------------------------------------------------
write_cstr:
	push	%rbx
	mov	%rdi, %rbx
	call	strlen
	mov	%rax, %rdx
	mov	%rbx, %rsi
	mov	$2, %edi
	call	write_full
	pop	%rbx
	ret

strlen:
	xor	%eax, %eax
.Lstrlen:
	cmpb	$0, (%rdi, %rax)
	je	.Lstrlen_done
	inc	%rax
	jmp	.Lstrlen
.Lstrlen_done:
	ret

# write_full: fd edi, buf rsi, len rdx. Short writes and EINTR are retried.
write_full:
	push	%r12
	push	%r13
	push	%r14
	mov	%edi, %r12d
	mov	%rsi, %r13
	mov	%rdx, %r14
.Lwloop:
	test	%r14, %r14
	jz	.Lwdone
	mov	%r12d, %edi
	mov	%r13, %rsi
	mov	%r14, %rdx
	mov	$SYS_write, %eax
	syscall
	cmp	$-EINTR, %rax
	je	.Lwloop
	test	%rax, %rax
	jle	.Lwdone
	add	%rax, %r13
	sub	%rax, %r14
	jmp	.Lwloop
.Lwdone:
	pop	%r14
	pop	%r13
	pop	%r12
	ret

# edi = status. Does not return.
sys_exit:
	mov	%edi, %eax
	mov	%rax, %rdi
	mov	$SYS_exit, %eax
	syscall
	jmp	sys_exit

.section .note.GNU-stack, "", @progbits
