/*
 *  ncid_network.c
 *  NCID
 *
 *  Created by Alexei Kosut on Mon Jan 27 2003.
 *  Copyright (c) 2003 Alexei Kosut. All rights reserved.
 *  Copyright (c) 2009 John Chmielewski. All rights reserved.
 *  Copyright (c) 2009-2010 Chris Lenderman. All rights reserved.
 *  Copyright (c) 2010 Nicholas Riley. All rights reserved.
 *
 */

#include "ncid_network.h"

//#ifdef WIN32
//#include <winsock.h>
//#else
#include <sys/types.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <syslog.h>
#include <unistd.h>
#include <netdb.h>
#include <arpa/inet.h>
#include <pthread.h>
//#endif
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define DEBUG 0

#ifndef MSG_WAITALL
#define MSG_WAITALL 0
#endif

/*
 #ifdef WIN32
typedef HANDLE pthread_mutex_t;
#define PTHREAD_MUTEX_INITIALIZER NULL
#define pthread_mutex_init(mutex, attr) *mutex = CreateMutex(NULL, FALSE, NULL)
#define pthread_mutex_unlock(mutex) ReleaseMutex(*mutex)
#define pthread_mutex_lock(mutex) mypthread_mutex_lock(mutex)
int mypthread_mutex_lock(HANDLE* mutex) {
    if (*mutex==NULL) *mutex = CreateMutex(NULL, FALSE, NULL);
    return WaitForSingleObject(*mutex,INFINITE)!=WAIT_OBJECT_0;
}

#define close closesocket
#define sleep(secs) Sleep(1000*(secs))

#define fprintf myprintf
static void myprintf(FILE *f, const char *fmt, ...) {
    char msg[1024];

    va_list ap;
    va_start(ap, fmt);
    vsprintf(msg, fmt, ap);
    va_end(ap);

    OutputDebugString(msg);
}

#define perror(str) myprintf(stderr, "%s: %s (%d)\n", (str), strerror(WSAGetLastError()), WSAGetLastError())
#endif
*/

static const short ncid_port = 3333;
static const int ncid_delay = 10;

static int no_one = 0;
static pthread_mutex_t list_mutex = PTHREAD_MUTEX_INITIALIZER;
static struct server_connection_data
{
    int s;
    int current_loop;
    pthread_mutex_t network_mutex;
    pthread_mutex_t socket_mutex;
    struct server_connection_data *next;
} *head = NULL;

static int connect_ncid(const char *servername, int this_loop, struct server_connection_data *data);
static const char *read_line(int s, char* buffer, int* length);
static void parse_cid(const char *line,
              void (*callback)(void *, const struct callerid_info *),
              void *context);
static void parse_cidinfo(const char *line,
              void (*callback)(void *, const struct calleridinfo_info *),
              void *context);
static const char *strcpyx(char *out, const char *in);

void add_connection(struct server_connection_data* connection)
{
    struct server_connection_data *temp;

    pthread_mutex_lock(&list_mutex);
    if (head == NULL)
    {
        head = connection;
    }
    else
    {
        temp = head;
        while (temp->next != NULL)
        {
            temp = temp->next;
        }
        temp->next = connection;
    }
    pthread_mutex_unlock(&list_mutex);
}

void delete_connection(struct server_connection_data *connection)
{
    struct server_connection_data *temp;
    pthread_mutex_lock(&list_mutex);
    temp = head;
    if (head == connection)
    {
        head = head->next;
    }
    else
    {
        temp = head;
        while(temp->next != connection && temp->next != NULL)
        {
            temp = temp->next;
        }
        if (temp->next == connection)
        {
            temp->next = temp->next->next;
        }
    }
    pthread_mutex_unlock(&list_mutex);
}

void ncid_network_loop(const char *servername,
               void (*connectcb)(void *, int connected),
               void (*new_call)(void *, const struct callerid_info *),
               void (*history)(void *, const struct callerid_info *),
               void (*call_info)(void *, const struct calleridinfo_info *),
               void (*messagecb)(void *, const char *message),
               void (*infocb)(void *, int messagenum, const char *message),
               void *context) {

    char buffer[1024];
    int length = 0;
    int this_loop;

    struct server_connection_data *sd = (struct server_connection_data*)malloc(sizeof(struct server_connection_data));
    sd->s = -1;
    sd->current_loop = 0;
    pthread_mutex_init(&sd->network_mutex, NULL);
    pthread_mutex_init(&sd->socket_mutex, NULL);
    sd->next = NULL;    
    add_connection(sd);
    
    if (pthread_mutex_lock(&sd->network_mutex))
        return;

    this_loop = ++sd->current_loop;
    while (sd->current_loop == this_loop) {
        const char *line;

        connectcb(context, 0);
        pthread_mutex_lock(&sd->socket_mutex);
        sd->s = connect_ncid(servername, this_loop, sd);
        pthread_mutex_unlock(&sd->socket_mutex);
        if (sd->s >= 0) {
            connectcb(context, 1);

            history(context, 0);

            while ((line = read_line(sd->s, buffer, &length)) != NULL) {
        #if DEBUG
                fprintf(stderr, "Received: %s\n", line);
        #endif
                if (!strncmp(line, "CID: ", 5)) {
                    parse_cid(line + 5, new_call, context);
                }
                else if (!strncmp(line, "CIDLOG: ", 8)) {
                    parse_cid(line + 8, history, context);
                }
                else if (!strncmp(line, "CIDINFO: ", 9)){
                    parse_cidinfo(line + 9, call_info, context);
                }
                else if (!strncmp(line, "MSG: ", 5)) {
                    messagecb(context, line + 5);
                }
                else if (!strncmp(line, "200 ", 4) ||
                         !strncmp(line, "300 ", 4)) {
                    infocb(context, atoi(line), line + 4);
                }
                /* Ignore other types of lines */
            }
            pthread_mutex_lock(&sd->socket_mutex);
            close(sd->s);
            pthread_mutex_unlock(&sd->socket_mutex);
        }
    }
    sd->s = -1;
    delete_connection(sd);

    pthread_mutex_unlock(&sd->network_mutex);

    free(sd);
    sd=NULL;
}

void ncid_network_kill() {
    struct server_connection_data *data;

    pthread_mutex_lock(&list_mutex);
    for (data = head; data!=NULL; data=data->next)
    {
        /* force ncid_network_loop() to exit for each socket connection*/
        data->current_loop++;
        pthread_mutex_lock(&data->socket_mutex);
        close(data->s);
        pthread_mutex_unlock(&data->socket_mutex);
    }
    pthread_mutex_unlock(&list_mutex);
}

void set_leading_one_state(int state) {
    no_one = !state;
}

static int connect_ncid(const char *servername, int this_loop, struct server_connection_data *data) {
    int delay_counter;
    for (;;) {
        struct sockaddr_in sin, addr;
        struct hostent *host;
        char hostname[256], *colon;
        short port;
        int s;

        s = socket(AF_INET, SOCK_STREAM, 0);
        if (s < 0) {
            perror("socket");
            exit(1);
        }

        addr.sin_family = AF_INET;
        addr.sin_addr.s_addr = htonl(INADDR_ANY);
        addr.sin_port = htons(0);

        if (bind(s, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
            perror("bind");
            exit(1);
        }

        strcpy(hostname, servername);
        colon = strchr(hostname, ':');
        if (colon != NULL) {
            port = atoi(colon + 1);
            *colon = 0;
        } else {
            port = ncid_port;
        }

        host = gethostbyname(hostname);
        if (host == NULL) {
            perror("gethostbyname");
            goto retry;
        }

    #ifndef WIN32
        sin.sin_len = sizeof(sin);
    #endif
        sin.sin_family = AF_INET;
        sin.sin_port = htons(port);
        sin.sin_addr.s_addr = *(unsigned long *)host->h_addr_list[0];
        memset(sin.sin_zero, 0, sizeof(sin.sin_zero));

    #if DEBUG
        fprintf(stderr, "Connecting to to %s:%d\n", inet_ntoa(sin.sin_addr), port);
    #endif

        if (connect(s, (struct sockaddr *)&sin, sizeof(sin)) < 0) {
            perror("connect");
            goto retry;
        }

    #if DEBUG
        fprintf(stderr, "Connected to %s\n", servername);
    #endif

        return s;

        retry:
            close(s);

            fprintf(stderr, "Cannot connect to the NCID server %s\n"
            "Retry in %d seconds\n", servername, ncid_delay);

            // Offer the ability to "break out" of our "wait" cycle
            delay_counter = ncid_delay;
            while (delay_counter-- > 0) {
                if (data->current_loop != this_loop)
                   return -1;
                sleep(1);
            }
    }
}

// Return 1 if the 10 digits at p are in the NANP format (NXX-NXX-XXXX).
static int is_nanp_number(const char *p)
{
    return (p[0] >= '2' && p[3] >= '2');
}

static const char *read_line(int s, char* buffer, int* length) {
    for (;;) {
        if (recv(s, buffer + *length, 1, 0) != 1) {
            *length = 0;
            return NULL;
        }

        if (buffer[*length] == '\n' || buffer[*length] == '\r') {
            buffer[*length] = 0;

            // Only return non-empty lines
            if (*length > 0)
                break;
        } else {
            ++*length;
        }
    }

    *length = 0;
    return buffer;
}

static void parse_cid(const char *line,
              void (*callback)(void *, const struct callerid_info *),
              void *context)
{
    struct callerid_info info;
    const char *p;
    const char *p2;

    memset(&info, 0, sizeof(info));

    // *DATE*
    if ((p = strstr(line, "*DATE*")) == NULL) return;
    p += 6;
    if ((p2 = strchr(p, '*')) == NULL) return;

    // 05112002*
    if ((p2 - p) == 8) {
        sprintf(info.date, "%.2s-%.2s-%.4s", p, p + 2, p + 4);
    } else {
        strcpyx(info.date, p);
    }

    // *TIME*
    if ((p = strstr(line, "*TIME*")) == NULL) return;
    p += 6;
    if ((p2 = strchr(p, '*')) == NULL) return;

    // 1525*
    if ((p2 - p) == 4) {
        char hourstr[3] = { p[0], p[1], 0 };
        int hour = atoi(hourstr);

        sprintf(info.time, "%d:%.2s %s", (hour % 12) ? hour % 12 : 12,
            p + 2,
            hour < 12 ? "AM" : "PM");
    } else {
        strcpyx(info.time, p);
    }

    // *LINE*
    if ((p = strstr(line, "*LINE*")) == NULL) return;
    p += 6;
    if ((p2 = strchr(p, '*')) == NULL) return;

    // Do not populate "line" if equal to a single dash
    if ( ((p2 - p) != 1) || strncmp(p, "-", 1)) {
        strcpyx(info.line, p);
    }

    // *NMBR*
    if ((p = strstr(line, "*NMBR*")) == NULL) return;
    p += 6;
    if ((p2 = strchr(p, '*')) == NULL) return;

    // 13215551234* or 3145551234* or 5551234* or 1234*
    if (isdigit(*p)) {
        if ((p2 - p) == 11) {
            info.is_nanp_number = is_nanp_number(p + 1);
            if (no_one) {
                sprintf(info.nmbr, "%.3s-%.3s-%.4s", p + 1, p + 4, p + 7);
            } else {
                sprintf(info.nmbr, "%.1s-%.3s-%.3s-%.4s", p, p + 1, p + 4, p + 7);
            }
        }
        else if ((p2 - p) == 10) {
            info.is_nanp_number = is_nanp_number(p);
            sprintf(info.nmbr, "%.3s-%.3s-%.4s", p, p + 3, p + 6);
        }
        else if ((p2 - p) == 7) {
            sprintf(info.nmbr, "%.3s-%.4s", p, p + 3);
        }
        else {
            strcpyx(info.nmbr, p);
        }
    } else {
        strcpyx(info.nmbr, p);
    }

    // *MESG*
//    if ((p = strstr(line, "*MESG*")) == NULL) return;
//    p += 6;
//    if ((p = strchr(p, '*')) == NULL) return;

    // *NAME*
    if ((p = strstr(line, "*NAME*")) == NULL) return;
    p += 6;

    strcpyx(info.name, p);

    callback(context, &info);
}

static void parse_cidinfo(const char *line,
              void (*callback)(void *, const struct calleridinfo_info *),
              void *context)
{
    struct calleridinfo_info info;
    const char *p;
    const char *p2;

    memset(&info,0,sizeof(info));

    // *LINE*
    if ((p = strstr(line, "*LINE*")) == NULL) return;
    p += 6;
    if ((p2 = strchr(p, '*')) == NULL) return;

    // Do not populate "line" if equal to a single dash
    if ( ((p2 - p) != 1) || strncmp(p, "-", 1)) {
        strcpyx(info.line, p);
    }

    // *RING*
    if ((p = strstr(line, "*RING*")) == NULL) return;
    p += 6;
    if (strchr(p, '*') == NULL) return;

    strcpyx(info.ring, p);

    callback(context, &info);
}

/* Copy until '*' or null terminator, whichever comes first.  Returns address of terminator.
 */
static const char *strcpyx(char *out, const char *in) {
    while (*in != '*' && *in != 0) {
        *(out++) = *(in++);
    }

    *out = 0;

    return in;
}

