#ifndef __USER_LIBS_FILE_H__
#define __USER_LIBS_FILE_H__

#include <defs.h>

struct stat;

int open(const char *path, uint32_t open_flags);
int close(int fd);
int read(int fd, void *base, size_t len);
int write(int fd, void *base, size_t len);
int seek(int fd, off_t pos, int whence);
int fstat(int fd, struct stat *stat);
int fsync(int fd);
int mkdir(const char *path);
int unlink(const char *path);
int rename(const char *old_path, const char *new_path);
int dup(int fd);
int dup2(int fd1, int fd2);
int pipe(int *fd_store);
int mkfifo(const char *name, uint32_t open_flags);
int board_display(uint32_t value);

void print_stat(const char *name, int fd, struct stat *stat);

#endif /* !__USER_LIBS_FILE_H__ */
