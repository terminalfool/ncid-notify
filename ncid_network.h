/*
 *  ncid_network.h
 *  NCID
 *
 *  Created by Alexei Kosut on Mon Jan 27 2003.
 *  Copyright (c) 2003 Alexei Kosut. All rights reserved.
 *
 */

#ifndef NCID_NETWORK_H
#define NCID_NETWORK_H

#ifdef __cplusplus
extern "C" {
#endif

struct callerid_info {
    char date[65];
    char time[65];
    char line[65];
    char nmbr[65];
    char name[65];
    int is_nanp_number;
};

struct calleridinfo_info {
    char line[65];
    char ring[65];
};

void ncid_network_loop(const char *servername,
		       void (*connectcb)(void *, int connected),
		       void (*new_call)(void *, const struct callerid_info *),
		       void (*history)(void *, const struct callerid_info *),
		       void (*call_info)(void *, const struct calleridinfo_info *),
		       void (*messagecb)(void *, const char *message),
		       void (*infocb)(void *, int messagenum, const char *message),
		       void *context);

void ncid_network_kill();
    
void set_leading_one_state(int state);

#ifdef __cplusplus
}
#endif

#endif
