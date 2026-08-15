#import "Libssh2SftpChannel.h"

#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <libssh2.h>
#include <libssh2_sftp.h>
#include <netdb.h>
#include <netinet/in.h>
#include <sys/select.h>
#include <sys/socket.h>
#include <unistd.h>

static NSString * const kWXIngestLibssh2Error = @"com.zkx.wechat.ingest.libssh2";

@implementation WXIngestLibssh2SftpChannel {
    NSString *_host;
    NSInteger _port;
    NSString *_username;
    NSString *_password;
    int _sock;
    LIBSSH2_SESSION *_session;
    LIBSSH2_SFTP *_sftp;
}

- (instancetype)initWithHost:(NSString *)host
                        port:(NSInteger)port
                    username:(NSString *)username
                    password:(NSString *)password {
    self = [super init];
    if (self) {
        _host = [host copy];
        _port = port > 0 ? port : 22;
        _username = [username copy];
        _password = [password copy];
        _sock = -1;
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            libssh2_init(0);
        });
    }
    return self;
}

- (void)dealloc {
    [self close];
}

- (BOOL)ensureConnected:(NSError **)error {
    if (_sftp != NULL) {
        return YES;
    }
    if (_host.length == 0 || _username.length == 0) {
        if (error) {
            *error = [NSError errorWithDomain:kWXIngestLibssh2Error
                                         code:1
                                     userInfo:@{NSLocalizedDescriptionKey: @"SSH host/user empty"}];
        }
        return NO;
    }

    struct addrinfo hints;
    memset(&hints, 0, sizeof(hints));
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    hints.ai_protocol = IPPROTO_TCP;
    char portC[8];
    snprintf(portC, sizeof(portC), "%ld", (long)_port);
    struct addrinfo *res = NULL;
    if (getaddrinfo(_host.UTF8String, portC, &hints, &res) != 0 || res == NULL) {
        if (error) {
            *error = [NSError errorWithDomain:kWXIngestLibssh2Error
                                         code:2
                                     userInfo:@{NSLocalizedDescriptionKey: @"DNS resolve failed"}];
        }
        return NO;
    }
    struct addrinfo *ordered[32];
    int n = 0;
    for (struct addrinfo *ai = res; ai && n < 32; ai = ai->ai_next) {
        if (ai->ai_family == AF_INET) {
            ordered[n++] = ai;
        }
    }
    for (struct addrinfo *ai = res; ai && n < 32; ai = ai->ai_next) {
        if (ai->ai_family != AF_INET) {
            ordered[n++] = ai;
        }
    }
    int sock = -1;
    for (int i = 0; i < n; i++) {
        struct addrinfo *ai = ordered[i];
        sock = socket(ai->ai_family, ai->ai_socktype, ai->ai_protocol);
        if (sock < 0) {
            continue;
        }
        int nosig = 1;
        setsockopt(sock, SOL_SOCKET, SO_NOSIGPIPE, &nosig, sizeof(nosig));
        int flags = fcntl(sock, F_GETFL, 0);
        fcntl(sock, F_SETFL, flags | O_NONBLOCK);
        int rc = connect(sock, ai->ai_addr, ai->ai_addrlen);
        BOOL ok = (rc == 0);
        if (!ok && errno == EINPROGRESS) {
            fd_set writeSet;
            FD_ZERO(&writeSet);
            FD_SET(sock, &writeSet);
            struct timeval tv;
            tv.tv_sec = 15;
            tv.tv_usec = 0;
            if (select(sock + 1, NULL, &writeSet, NULL, &tv) > 0) {
                int socketError = 0;
                socklen_t len = sizeof(socketError);
                getsockopt(sock, SOL_SOCKET, SO_ERROR, &socketError, &len);
                ok = (socketError == 0);
            }
        }
        fcntl(sock, F_SETFL, flags);
        if (ok) {
            break;
        }
        close(sock);
        sock = -1;
    }
    freeaddrinfo(res);
    if (sock < 0) {
        if (error) {
            *error = [NSError errorWithDomain:kWXIngestLibssh2Error
                                         code:3
                                     userInfo:@{NSLocalizedDescriptionKey: @"TCP connect failed"}];
        }
        return NO;
    }

    LIBSSH2_SESSION *session = libssh2_session_init();
    if (session == NULL) {
        close(sock);
        if (error) {
            *error = [NSError errorWithDomain:kWXIngestLibssh2Error
                                         code:4
                                     userInfo:@{NSLocalizedDescriptionKey: @"libssh2 session init failed"}];
        }
        return NO;
    }
    libssh2_session_set_blocking(session, 1);
    if (libssh2_session_handshake(session, sock) != 0) {
        libssh2_session_free(session);
        close(sock);
        if (error) {
            *error = [NSError errorWithDomain:kWXIngestLibssh2Error
                                         code:5
                                     userInfo:@{NSLocalizedDescriptionKey: @"SSH handshake failed"}];
        }
        return NO;
    }
    if (libssh2_userauth_password(session, _username.UTF8String, (_password ?: @"").UTF8String) != 0) {
        libssh2_session_disconnect(session, "auth failed");
        libssh2_session_free(session);
        close(sock);
        if (error) {
            *error = [NSError errorWithDomain:kWXIngestLibssh2Error
                                         code:6
                                     userInfo:@{NSLocalizedDescriptionKey: @"SSH password auth failed"}];
        }
        return NO;
    }
    LIBSSH2_SFTP *sftp = libssh2_sftp_init(session);
    if (sftp == NULL) {
        libssh2_session_disconnect(session, "sftp failed");
        libssh2_session_free(session);
        close(sock);
        if (error) {
            *error = [NSError errorWithDomain:kWXIngestLibssh2Error
                                         code:7
                                     userInfo:@{NSLocalizedDescriptionKey: @"SFTP init failed"}];
        }
        return NO;
    }
    _sock = sock;
    _session = session;
    _sftp = sftp;
    return YES;
}

- (BOOL)mkdirParents:(NSString *)path {
    if (_sftp == NULL) {
        return NO;
    }
    NSArray<NSString *> *parts = [path pathComponents];
    NSString *cur = @"";
    for (NSString *part in parts) {
        if (part.length == 0 || [part isEqualToString:@"/"]) {
            cur = @"/";
            continue;
        }
        cur = [cur isEqualToString:@"/"] ? [cur stringByAppendingString:part]
                                         : [cur stringByAppendingPathComponent:part];
        libssh2_sftp_mkdir(_sftp, cur.UTF8String, 0755);
    }
    return YES;
}

- (BOOL)putData:(NSData *)data toPath:(NSString *)remotePath error:(NSError **)error {
    if (![self ensureConnected:error]) {
        return NO;
    }
    [self mkdirParents:[remotePath stringByDeletingLastPathComponent]];
    LIBSSH2_SFTP_HANDLE *handle = libssh2_sftp_open(
        _sftp,
        remotePath.UTF8String,
        LIBSSH2_FXF_WRITE | LIBSSH2_FXF_CREAT | LIBSSH2_FXF_TRUNC,
        0644);
    if (handle == NULL) {
        [self close];
        if (error) {
            *error = [NSError errorWithDomain:kWXIngestLibssh2Error
                                         code:8
                                     userInfo:@{NSLocalizedDescriptionKey: @"SFTP open failed"}];
        }
        return NO;
    }
    const char *bytes = data.bytes;
    size_t left = data.length;
    while (left > 0) {
        ssize_t n = libssh2_sftp_write(handle, bytes, left);
        if (n < 0) {
            libssh2_sftp_close(handle);
            [self close];
            if (error) {
                *error = [NSError errorWithDomain:kWXIngestLibssh2Error
                                             code:9
                                         userInfo:@{NSLocalizedDescriptionKey: @"SFTP write failed"}];
            }
            return NO;
        }
        bytes += n;
        left -= (size_t)n;
    }
    libssh2_sftp_close(handle);
    return YES;
}

- (BOOL)putFile:(NSString *)localPath toPath:(NSString *)remotePath error:(NSError **)error {
    if (localPath.length == 0) {
        return NO;
    }
    FILE *fp = fopen(localPath.fileSystemRepresentation, "rb");
    if (fp == NULL) {
        if (error) {
            *error = [NSError errorWithDomain:kWXIngestLibssh2Error
                                         code:11
                                     userInfo:@{NSLocalizedDescriptionKey: @"local file open failed"}];
        }
        return NO;
    }
    if (![self ensureConnected:error]) {
        fclose(fp);
        return NO;
    }
    [self mkdirParents:[remotePath stringByDeletingLastPathComponent]];
    LIBSSH2_SFTP_HANDLE *handle = libssh2_sftp_open(
        _sftp,
        remotePath.UTF8String,
        LIBSSH2_FXF_WRITE | LIBSSH2_FXF_CREAT | LIBSSH2_FXF_TRUNC,
        0644);
    if (handle == NULL) {
        fclose(fp);
        [self close];
        if (error) {
            *error = [NSError errorWithDomain:kWXIngestLibssh2Error
                                         code:8
                                     userInfo:@{NSLocalizedDescriptionKey: @"SFTP open failed"}];
        }
        return NO;
    }
    char buf[32768];
    size_t nread;
    while ((nread = fread(buf, 1, sizeof(buf), fp)) > 0) {
        const char *p = buf;
        size_t left = nread;
        while (left > 0) {
            ssize_t n = libssh2_sftp_write(handle, p, left);
            if (n < 0) {
                libssh2_sftp_close(handle);
                fclose(fp);
                [self close];
                if (error) {
                    *error = [NSError errorWithDomain:kWXIngestLibssh2Error
                                                 code:9
                                             userInfo:@{NSLocalizedDescriptionKey: @"SFTP write failed"}];
                }
                return NO;
            }
            p += n;
            left -= (size_t)n;
        }
    }
    libssh2_sftp_close(handle);
    fclose(fp);
    return YES;
}

- (NSData *)dataFromPath:(NSString *)remotePath error:(NSError **)error {
    if (![self ensureConnected:error]) {
        return nil;
    }
    LIBSSH2_SFTP_HANDLE *handle = libssh2_sftp_open(_sftp, remotePath.UTF8String, LIBSSH2_FXF_READ, 0);
    if (handle == NULL) {
        if (error) {
            *error = [NSError errorWithDomain:kWXIngestLibssh2Error
                                         code:10
                                     userInfo:@{NSLocalizedDescriptionKey: @"SFTP read open failed"}];
        }
        return nil;
    }
    NSMutableData *data = [NSMutableData data];
    char buf[8192];
    for (;;) {
        ssize_t n = libssh2_sftp_read(handle, buf, sizeof(buf));
        if (n > 0) {
            [data appendBytes:buf length:(NSUInteger)n];
            continue;
        }
        break;
    }
    libssh2_sftp_close(handle);
    return data;
}

- (void)close {
    LIBSSH2_SFTP *sftp = _sftp;
    LIBSSH2_SESSION *session = _session;
    int sock = _sock;
    _sftp = NULL;
    _session = NULL;
    _sock = -1;
    if (sftp) {
        libssh2_sftp_shutdown(sftp);
    }
    if (session) {
        libssh2_session_set_blocking(session, 0);
        libssh2_session_disconnect(session, "bye");
        libssh2_session_free(session);
    }
    if (sock >= 0) {
        close(sock);
    }
}

@end
