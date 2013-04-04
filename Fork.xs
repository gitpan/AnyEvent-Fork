/* GetCurrentProcessId is XP and up, which means in all supported versions */
/* but older SDK's might need this */
#define _WIN32_WINNT NTDDI_WINXP

#ifdef __sun
  #define _XOPEN_SOURCE 1
  #define _XOPEN_SOURCE_EXTENDED 1
  #define __EXTENSIONS__ 1
#endif

#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"

#if WIN32

  /* perl probably did this already */
  #include <windows.h>

#elif __CYGWIN__

  #include <windows.h>
  #include <io.h>
  #include <sys/cygwin.h>

  #define ioctlsocket(a,b,c) ioctl (a, b, c)
  #define _open_osfhandle(h,m) cygwin_attach_handle_to_fd ("/dev/pipe", -1, (HANDLE)h, 1, GENERIC_READ | GENERIC_WRITE)
  typedef int SOCKET;

#else

  #include <stddef.h> // needed by broken bsds for NULL used in sys/uio.h
  #include <stdlib.h>
  #include <errno.h>

  /* send_fd/recv_fd taken from libptytty */
  #include <sys/types.h>
  #include <sys/uio.h>
  #include <sys/socket.h>

  #ifndef CMSG_SPACE
  # define CMSG_SPACE(len) (sizeof (cmsghdr) + len)
  #endif

  #ifndef CMSG_LEN
  # define CMSG_LEN(len) (sizeof (cmsghdr) + len)
  #endif

#endif

static u_long on  = 1;
static u_long off = 0;

static int
fd_send (int socket, int fd)
{
#if defined(WIN32)
  DWORD pid;
  HANDLE target, h;
  SOCKET s = (SOCKET)socket; /* we require USE_SOCKETS_AS_HANDLES */

  /* seriously, there is no way to query whether a socket is non-blocking?? */
  ioctlsocket (s, FIONBIO, &off);
  if (recv (s, (char *)&pid, sizeof (pid), 0) != sizeof (pid))
    return 0;

  target = OpenProcess (PROCESS_DUP_HANDLE, FALSE, pid);
  if (!target)
    croak ("AnyEvent::ProcessPool::fd_recv: OpenProcess failed");

  if (!DuplicateHandle ((HANDLE)-1, (HANDLE)_get_osfhandle (fd), target, &h, 0, FALSE, DUPLICATE_SAME_ACCESS))
    croak ("AnyEvent::ProcessPool::fd_recv: DuplicateHandle failed");

  CloseHandle (target);

  if (send (s, (char *)&h, sizeof (h), 0) != sizeof (h))
    return 0;

  ioctlsocket (s, FIONBIO, &on);

  return 1;

#else
  void *buf = malloc (CMSG_SPACE (sizeof (int)));

  if (!buf)
    return 0;

  struct msghdr msg;
  struct iovec iov;
  struct cmsghdr *cmsg;
  char data = 0;

  iov.iov_base = &data;
  iov.iov_len  = 1;

  msg.msg_name       = 0;
  msg.msg_namelen    = 0;
  msg.msg_iov        = &iov;
  msg.msg_iovlen     = 1;
  msg.msg_control    = buf;
  msg.msg_controllen = CMSG_SPACE (sizeof (int));

  cmsg = CMSG_FIRSTHDR (&msg);
  cmsg->cmsg_level = SOL_SOCKET;
  cmsg->cmsg_type  = SCM_RIGHTS;
  cmsg->cmsg_len   = CMSG_LEN (sizeof (int));

  *(int *)CMSG_DATA (cmsg) = fd;

  ssize_t result = sendmsg (socket, &msg, 0);

  free (buf);

  return result >= 0;
#endif
}

static int
fd_recv (int socket)
{
#if defined(WIN32)
  DWORD pid = GetCurrentProcessId ();
  SOCKET s = (SOCKET)socket; /* we require USE_SOCKETS_AS_HANDLES */
  HANDLE h;

  ioctlsocket (s, FIONBIO, &off);

  if (send (s, (char *)&pid, sizeof (pid), 0) != sizeof (pid))
    return -1;

  if (recv (s, (char *)&h, sizeof (h), 0) != sizeof (h))
    return -1;

  ioctlsocket (s, FIONBIO, &on);

  return _open_osfhandle ((intptr_t)h, 0);
#else
  void *buf = malloc (CMSG_SPACE (sizeof (int)));

  if (!buf)
    return -1;

  struct msghdr msg;
  struct iovec iov;
  char data = 1;

  iov.iov_base = &data;
  iov.iov_len  = 1;

  msg.msg_name       = 0;
  msg.msg_namelen    = 0;
  msg.msg_iov        = &iov;
  msg.msg_iovlen     = 1;
  msg.msg_control    = buf;
  msg.msg_controllen = CMSG_SPACE (sizeof (int));

  if (recvmsg (socket, &msg, 0) <= 0)
    return -1;

  int fd = -1;

  errno = EDOM;

  if (data == 0 && msg.msg_controllen >= CMSG_SPACE (sizeof (int)))
    {
      struct cmsghdr *cmsg = CMSG_FIRSTHDR (&msg);

      if (cmsg->cmsg_level   == SOL_SOCKET
          && cmsg->cmsg_type == SCM_RIGHTS
          && cmsg->cmsg_len  >= CMSG_LEN (sizeof (int)))
        fd = *(int *)CMSG_DATA (cmsg);
    }

  free (buf);

  return fd;
#endif
}

MODULE = AnyEvent::Fork		PACKAGE = AnyEvent::Fork::Util

PROTOTYPES: ENABLE

BOOT:
{
	HV *stash = gv_stashpv ("AnyEvent::Fork::Util", 1);
#if defined(WIN32) && !__CYGWIN__
        newCONSTSUB (stash, "WIN32", &PL_sv_yes);
#else
        newCONSTSUB (stash, "WIN32", &PL_sv_no);
#endif
}

void
_exit (int status)

int
fd_send (int socket, int fd)

int
fd_recv (int socket)

