#include <ulib.h>
#include <stdio.h>
#include <string.h>
#include <dir.h>
#include <file.h>
#include <error.h>
#include <unistd.h>
#include <stat.h>

#define printf(...)                     fprintf(1, __VA_ARGS__)
#define putc(c)                         printf("%c", c)

#define BUFSIZE                         4096
#define WHITESPACE                      " \t\r\n"
#define SYMBOLS                         "<|>&;"

char shcwd[BUFSIZE];

static uint32_t
crc32_update(uint32_t crc, const void *data, size_t len) {
    const unsigned char *p = data;
    crc = ~crc;
    while (len -- > 0) {
        crc ^= *p ++;
        int i;
        for (i = 0; i < 8; i ++) {
            crc = (crc >> 1) ^ (0xedb88320U & -(crc & 1));
        }
    }
    return ~crc;
}

static int
parse_uint(const char *s, uint32_t *value, int base) {
    uint32_t v = 0;
    if (*s == '\0') return -E_INVAL;
    while (*s != '\0') {
        int d;
        if (*s >= '0' && *s <= '9') d = *s - '0';
        else if (*s >= 'a' && *s <= 'f') d = *s - 'a' + 10;
        else if (*s >= 'A' && *s <= 'F') d = *s - 'A' + 10;
        else return -E_INVAL;
        if (d >= base) return -E_INVAL;
        v = v * base + d;
        s ++;
    }
    *value = v;
    return 0;
}

static int
write_all(int fd, const void *data, size_t len) {
    const char *p = data;
    while (len != 0) {
        int ret = write(fd, (void *)p, len);
        if (ret <= 0) return ret < 0 ? ret : -E_UNSPECIFIED;
        p += ret, len -= ret;
    }
    return 0;
}

static char *
protocol_readline(void) {
    static char line[BUFSIZE];
    int len = 0;
    while (1) {
        char c;
        int ret = read(0, &c, 1);
        if (ret <= 0) return NULL;
        if (c == '\r' || c == '\n') {
            if (len == 0) continue;
            line[len] = '\0';
            return line;
        }
        if (len < BUFSIZE - 1) line[len ++] = c;
    }
}

static int
split_words(char *line, char **argv, int maxargs) {
    int argc = 0;
    while (*line != '\0') {
        while (strchr(WHITESPACE, *line) != NULL) *line ++ = '\0';
        if (*line == '\0') break;
        if (argc == maxargs) return -E_TOO_BIG;
        argv[argc ++] = line;
        while (*line != '\0' && strchr(WHITESPACE, *line) == NULL) line ++;
    }
    return argc;
}

static int
hex_decode(const char *hex, unsigned char *out, size_t len) {
    size_t i;
    for (i = 0; i < len; i ++) {
        char pair[3] = {hex[i * 2], hex[i * 2 + 1], '\0'};
        uint32_t value;
        if (pair[0] == '\0' || pair[1] == '\0' || parse_uint(pair, &value, 16) != 0) return -E_INVAL;
        out[i] = value;
    }
    return hex[len * 2] == '\0' ? 0 : -E_INVAL;
}

static void
hex_encode(const unsigned char *data, size_t len, char *hex) {
    static const char digits[] = "0123456789ABCDEF";
    size_t i;
    for (i = 0; i < len; i ++) {
        hex[i * 2] = digits[data[i] >> 4];
        hex[i * 2 + 1] = digits[data[i] & 15];
    }
    hex[len * 2] = '\0';
}

static int
xput(const char *path, uint32_t expected_size, uint32_t expected_crc) {
    char temp[FS_MAX_FNAME_LEN + 1];
    if (strlen(path) + 5 >= sizeof(temp)) return -E_TOO_BIG;
    snprintf(temp, sizeof(temp), "%s.part", path);
    unlink(temp);
    int fd = open(temp, O_WRONLY | O_CREAT | O_TRUNC);
    if (fd < 0) return fd;
    board_display(0xF1000000);
    printf("XREADY PUT\n");
    uint32_t total = 0, crc = 0, next_seq = 0;
    int ret = 0;
    while (total < expected_size) {
        char *line = protocol_readline();
        char *args[6];
        int argc;
        if (line == NULL || (argc = split_words(line, args, 6)) != 5 || strcmp(args[0], "D") != 0) {
            ret = -E_INVAL;
            break;
        }
        uint32_t seq, len, chunk_crc;
        if (parse_uint(args[1], &seq, 10) || parse_uint(args[2], &len, 10) ||
            parse_uint(args[3], &chunk_crc, 16) || len > 128) {
            ret = -E_INVAL;
            break;
        }
        if (next_seq > 0 && seq == next_seq - 1) {
            printf("ACK %d\n", seq);
            continue;
        }
        if (seq != next_seq || total + len > expected_size) {
            ret = -E_INVAL;
            break;
        }
        unsigned char data[128];
        if ((ret = hex_decode(args[4], data, len)) != 0 || crc32_update(0, data, len) != chunk_crc) {
            ret = -E_INVAL;
            break;
        }
        if ((ret = write_all(fd, data, len)) != 0) break;
        crc = crc32_update(crc, data, len);
        total += len, next_seq ++;
        board_display(0xF1000000 | (total & 0x00ffffff));
        printf("ACK %d\n", seq);
    }
    if (ret == 0 && (total != expected_size || crc != expected_crc)) ret = -E_INVAL;
    if (ret == 0) ret = fsync(fd);
    close(fd);
    if (ret == 0) {
        unlink(path);
        ret = rename(temp, path);
    }
    if (ret != 0) {
        unlink(temp);
        board_display(0xE1000000 | ((-ret) & 0xffff));
        printf("XERR %d\n", ret);
        return ret;
    }
    board_display(0xA1000000 | (total & 0x00ffffff));
    printf("XDONE %x\n", crc);
    return 0;
}

static int
xget(const char *path) {
    int fd = open(path, O_RDONLY);
    if (fd < 0) return fd;
    struct stat st;
    int ret = fstat(fd, &st);
    if (ret != 0 || !S_ISREG(st.st_mode)) {
        close(fd);
        return ret != 0 ? ret : -E_ISDIR;
    }
    unsigned char data[128];
    uint32_t crc = 0;
    int len;
    while ((len = read(fd, data, sizeof(data))) > 0) crc = crc32_update(crc, data, len);
    if (len < 0 || seek(fd, 0, LSEEK_SET) != 0) {
        close(fd);
        return len < 0 ? len : -E_SEEK;
    }
    board_display(0xF2000000);
    printf("XMETA %d %x\n", st.st_size, crc);
    uint32_t seq = 0, total = 0;
    char hex[257];
    while ((len = read(fd, data, sizeof(data))) > 0) {
        uint32_t chunk_crc = crc32_update(0, data, len);
        hex_encode(data, len, hex);
        printf("D %d %d %x %s\n", seq, len, chunk_crc, hex);
        char *line = protocol_readline();
        char *args[3];
        int argc = line == NULL ? 0 : split_words(line, args, 3);
        if (line != NULL && strcmp(line, "XCANCEL") == 0) {
            close(fd);
            printf("XCANCELLED\n");
            return 0;
        }
        uint32_t ack;
        if (argc != 2 || strcmp(args[0], "ACK") != 0 || parse_uint(args[1], &ack, 10) || ack != seq) {
            ret = -E_INVAL;
            break;
        }
        total += len, seq ++;
        board_display(0xF2000000 | (total & 0x00ffffff));
    }
    close(fd);
    if (len < 0 && ret == 0) ret = len;
    if (ret != 0) {
        board_display(0xE2000000 | ((-ret) & 0xffff));
        printf("XERR %d\n", ret);
        return ret;
    }
    board_display(0xA2000000 | (total & 0x00ffffff));
    printf("XDONE %x\n", crc);
    return 0;
}

static int
copy_file(const char *src, const char *dst) {
    int in = open(src, O_RDONLY);
    if (in < 0) return in;
    int out = open(dst, O_WRONLY | O_CREAT | O_TRUNC);
    if (out < 0) { close(in); return out; }
    char data[512];
    int len, ret = 0;
    while ((len = read(in, data, sizeof(data))) > 0) {
        if ((ret = write_all(out, data, len)) != 0) break;
    }
    if (len < 0 && ret == 0) ret = len;
    if (ret == 0) ret = fsync(out);
    close(in), close(out);
    return ret;
}

static int
show_file(const char *path) {
    int fd = open(path, O_RDONLY);
    if (fd < 0) return fd;
    char data[512];
    int len, ret = 0;
    while ((len = read(fd, data, sizeof(data))) > 0) {
        if ((ret = write_all(1, data, len)) != 0) break;
    }
    close(fd);
    return len < 0 && ret == 0 ? len : ret;
}

static int
list_dir(const char *path) {
    DIR *dir = opendir(path);
    if (dir == NULL) return -E_NOTDIR;
    struct dirent *entry;
    while ((entry = readdir(dir)) != NULL) printf("%s\n", entry->name);
    closedir(dir);
    return 0;
}

static int
run_builtin(char *command, int *handled) {
    static char line[BUFSIZE];
    char *argv[EXEC_MAX_ARG_NUM];
    strcpy(line, command);
    int argc = split_words(line, argv, EXEC_MAX_ARG_NUM);
    *handled = 1;
    if (argc <= 0) return 0;
    if (strcmp(argv[0], "cd") == 0) return argc == 2 ? chdir(argv[1]) : -E_INVAL;
    if (strcmp(argv[0], "pwd") == 0) {
        char cwd[BUFSIZE];
        int ret = argc == 1 ? getcwd(cwd, sizeof(cwd)) : -E_INVAL;
        if (ret == 0) printf("%s\n", cwd);
        return ret;
    }
    if (strcmp(argv[0], "mkdir") == 0) return argc == 2 ? mkdir(argv[1]) : -E_INVAL;
    if (strcmp(argv[0], "rm") == 0) return argc == 2 ? unlink(argv[1]) : -E_INVAL;
    if (strcmp(argv[0], "ls") == 0) return argc == 1 ? list_dir(".") : argc == 2 ? list_dir(argv[1]) : -E_INVAL;
    if (strcmp(argv[0], "cat") == 0) return argc == 2 ? show_file(argv[1]) : -E_INVAL;
    if (strcmp(argv[0], "mv") == 0) return argc == 3 ? rename(argv[1], argv[2]) : -E_INVAL;
    if (strcmp(argv[0], "cp") == 0) return argc == 3 ? copy_file(argv[1], argv[2]) : -E_INVAL;
    if (strcmp(argv[0], "write") == 0) {
        if (argc < 3) return -E_INVAL;
        int fd = open(argv[1], O_WRONLY | O_CREAT | O_TRUNC);
        if (fd < 0) return fd;
        int ret = 0, i;
        for (i = 2; i < argc && ret == 0; i ++) {
            if (i != 2) ret = write_all(fd, " ", 1);
            if (ret == 0) ret = write_all(fd, argv[i], strlen(argv[i]));
        }
        if (ret == 0) ret = write_all(fd, "\n", 1);
        if (ret == 0) ret = fsync(fd);
        close(fd);
        return ret;
    }
    if (strcmp(argv[0], "stat") == 0) {
        if (argc != 2) return -E_INVAL;
        int fd = open(argv[1], O_RDONLY);
        if (fd < 0) return fd;
        struct stat st;
        int ret = fstat(fd, &st);
        if (ret == 0) print_stat(argv[1], fd, &st);
        close(fd);
        return ret;
    }
    if (strcmp(argv[0], "display") == 0) {
        uint32_t value;
        return argc == 2 && parse_uint(argv[1], &value, 16) == 0 ? board_display(value) : -E_INVAL;
    }
    if (strcmp(argv[0], "xput") == 0) {
        uint32_t size, crc;
        return argc == 4 && parse_uint(argv[2], &size, 10) == 0 && parse_uint(argv[3], &crc, 16) == 0
            ? xput(argv[1], size, crc) : -E_INVAL;
    }
    if (strcmp(argv[0], "xget") == 0) return argc == 2 ? xget(argv[1]) : -E_INVAL;
    if (strcmp(argv[0], "XCANCEL") == 0) {
        if (argc != 1) return -E_INVAL;
        printf("XCANCELLED\n");
        return 0;
    }
    if (strcmp(argv[0], "help") == 0) {
        printf("builtins: cd pwd ls cat mkdir rm mv cp write stat display xput xget help\n");
        return 0;
    }
    *handled = 0;
    return 0;
}

int
gettoken(char **p1, char **p2) {
    char *s;
    if ((s = *p1) == NULL) {
        return 0;
    }
    while (strchr(WHITESPACE, *s) != NULL) {
        *s ++ = '\0';
    }
    if (*s == '\0') {
        return 0;
    }

    *p2 = s;
    int token = 'w';
    if (strchr(SYMBOLS, *s) != NULL) {
        token = *s, *s ++ = '\0';
    }
    else {
        bool flag = 0;
        while (*s != '\0' && (flag || strchr(WHITESPACE SYMBOLS, *s) == NULL)) {
            if (*s == '"') {
                *s = ' ', flag = !flag;
            }
            s ++;
        }
    }
    *p1 = (*s != '\0' ? s : NULL);
    return token;
}

char *
readline(const char *prompt) {
    static char buffer[BUFSIZE];
    if (prompt != NULL) {
        printf("%s", prompt);
    }
    int ret, i = 0, escape = 0;
    while (1) {
        char c;
        if ((ret = read(0, &c, sizeof(char))) < 0) {
            return NULL;
        }
        else if (ret == 0) {
            if (i > 0) {
                buffer[i] = '\0';
                break;
            }
            return NULL;
        }

        if (escape != 0) {
            if (escape == 1 && c == '[') {
                escape = 2;
            }
            else if (escape == 1 || (c >= '@' && c <= '~')) {
                escape = 0;
            }
            continue;
        }

        if (c == 27) {
            escape = 1;
        }
        else if (c == 3) {
            return NULL;
        }
        else if ( (c == '\b' || c == 127)) {
            if (i > 0) {
                printf("\b \b");
                i --;
            }
        }
        else if (c == '\n' || c == '\r') {
            putc(c);
            buffer[i] = '\0';
            break;
        }
        else if (c >= ' ' && i < BUFSIZE - 1) {
            putc(c);
            buffer[i ++] = c;
        }
    }
    return buffer;
}

void
usage(void) {
    printf("usage: sh [command-file]\n");
}

int
reopen(int fd2, const char *filename, uint32_t open_flags) {
    int ret, fd1;
    close(fd2);
    if ((ret = open(filename, open_flags)) >= 0 && ret != fd2) {
        close(fd2);
        fd1 = ret, ret = dup2(fd1, fd2);
        close(fd1);
    }
    return ret < 0 ? ret : 0;
}

int
testfile(const char *name) {
    int ret;
    if ((ret = open(name, O_RDONLY)) < 0) {
        return ret;
    }
    close(ret);
    return 0;
}

int
runcmd(char *cmd) {
    static char argv0[BUFSIZE];
    const char *argv[EXEC_MAX_ARG_NUM + 1];
    char *t;
    int argc, token, ret, p[2];
again:
    argc = 0;
    while (1) {
        switch (token = gettoken(&cmd, &t)) {
        case 'w':
            if (argc == EXEC_MAX_ARG_NUM) {
                printf("sh error: too many arguments\n");
                return -1;
            }
            argv[argc ++] = t;
            break;
        case '<':
            if (gettoken(&cmd, &t) != 'w') {
                printf("sh error: syntax error: < not followed by word\n");
                return -1;
            }
            if ((ret = reopen(0, t, O_RDONLY)) != 0) {
                return ret;
            }
            break;
        case '>':
            if (gettoken(&cmd, &t) != 'w') {
                printf("sh error: syntax error: > not followed by word\n");
                return -1;
            }
            if ((ret = reopen(1, t, O_RDWR | O_TRUNC | O_CREAT)) != 0) {
                return ret;
            }
            break;
        case '|':
          //  if ((ret = pipe(p)) != 0) {
          //      return ret;
          //  }
            if ((ret = fork()) == 0) {
                close(0);
                if ((ret = dup2(p[0], 0)) < 0) {
                    return ret;
                }
                close(p[0]), close(p[1]);
                goto again;
            }
            else {
                if (ret < 0) {
                    return ret;
                }
                close(1);
                if ((ret = dup2(p[1], 1)) < 0) {
                    return ret;
                }
                close(p[0]), close(p[1]);
                goto runit;
            }
            break;
        case 0:
            goto runit;
        case ';':
            if ((ret = fork()) == 0) {
                goto runit;
            }
            else {
                if (ret < 0) {
                    return ret;
                }
                waitpid(ret, NULL);
                goto again;
            }
            break;
        default:
            printf("sh error: bad return %d from gettoken\n", token);
            return -1;
        }
    }

runit:
    if (argc == 0) {
        return 0;
    }
    else if (strcmp(argv[0], "cd") == 0) {
        if (argc != 2) {
            return -1;
        }
        strcpy(shcwd, argv[1]);
        return 0;
    }
    if ((ret = testfile(argv[0])) != 0) {
        if (ret != -E_NOENT) {
            return ret;
        }
        snprintf(argv0, sizeof(argv0), "/%s", argv[0]);
        argv[0] = argv0;
    }
    argv[argc] = NULL;
    return __exec(NULL, argv);
}

int
main(int argc, char **argv) {
	printf("user sh is running!!!\n");
    int ret, interactive = 1;
    if (argc == 2) {
        if ((ret = reopen(0, argv[1], O_RDONLY)) != 0) {
            return ret;
        }
        interactive = 0;
    }
    else if (argc > 2) {
        usage();
        return -1;
    }
    //shcwd = malloc(BUFSIZE);
    assert(shcwd != NULL);

    char *buffer;
    while ((buffer = readline((interactive) ? "$ " : NULL)) != NULL) {
        printf("\r\n");
        int handled;
        ret = run_builtin(buffer, &handled);
        if (handled) {
            if (ret != 0) printf("error: %d - %e\n", ret, ret);
            continue;
        }
        shcwd[0] = '\0';
        int pid;
        if ((pid = fork()) == 0) {
            ret = runcmd(buffer);
            exit(ret);
        }
        assert(pid >= 0);
        if (waitpid(pid, &ret) == 0) {
            if (ret == 0 && shcwd[0] != '\0') {
				ret = 0;
            }
            if (ret != 0) {
                printf("error: %d - %e\n", ret, ret);
            }
        }
    }
    return 0;
}
