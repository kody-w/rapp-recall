#ifndef RAPP_RECALL_SQLITE_H
#define RAPP_RECALL_SQLITE_H

#include "sqlite3.h"

int recall_sqlite_key(sqlite3 *database, const void *key, int key_length);

#endif
