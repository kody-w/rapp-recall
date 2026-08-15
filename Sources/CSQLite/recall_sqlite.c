#include "recall_sqlite.h"

int recall_sqlite_key(sqlite3 *database, const void *key, int key_length) {
  return sqlite3_key(database, key, key_length);
}
