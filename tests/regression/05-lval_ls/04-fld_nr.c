#include <pthread.h>

int glob;

struct {
  pthread_mutex_t x;
  pthread_mutex_t y;
} m;

void *t_fun(void *arg) {
  pthread_mutex_lock(&m.x);
  glob++; // NOWARN!
  pthread_mutex_unlock(&m.x);
  return NULL;
}

int main() {
  pthread_t id;
  pthread_create(&id, NULL, t_fun, NULL);
  pthread_mutex_lock(&m.x);
  glob++; // NOWARN!
  pthread_mutex_lock(&m.x);
  return 0;
}


