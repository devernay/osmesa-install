/* Multithreaded OSMesa test: each thread creates its own context and renders its own color
 * into its own buffer (all buffers have the same size, which triggered buffer sharing in
 * unpatched Mesa <= 20.x), then checks that the buffer only contains its color.
 * Build with -DMANGLED to call the mgl* functions of a mangled OSMesa.
 * Usage: osmesa_mt_test [threads] [iterations]
 */
#ifdef MANGLED
#include <GL/gl_mangle.h>
#endif
#include <GL/osmesa.h>
#include <GL/gl.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>

#define W 256
#define H 256

static int iterations = 200;
static int failures = 0;
static pthread_mutex_t failures_mutex = PTHREAD_MUTEX_INITIALIZER;

static void *render(void *arg)
{
    int id = (int)(long)arg;
    const int attribs[] = { OSMESA_FORMAT, OSMESA_RGBA, OSMESA_DEPTH_BITS, 24,
                            OSMESA_PROFILE, OSMESA_COMPAT_PROFILE, 0 };
    OSMesaContext ctx = OSMesaCreateContextAttribs(attribs, NULL);
    unsigned char *buf = malloc(W * H * 4);
    /* a color unique to this thread */
    unsigned char r = (unsigned char)(37 * id + 11), g = (unsigned char)(91 * id + 23), b = (unsigned char)(53 * id + 47);
    int it, i, bad = 0;

    if (!ctx || !buf) {
        fprintf(stderr, "thread %d: context creation failed\n", id);
        pthread_mutex_lock(&failures_mutex);
        failures++;
        pthread_mutex_unlock(&failures_mutex);
        return NULL;
    }
    for (it = 0; it < iterations && !bad; it++) {
        if (!OSMesaMakeCurrent(ctx, buf, GL_UNSIGNED_BYTE, W, H)) {
            fprintf(stderr, "thread %d: OSMesaMakeCurrent failed\n", id);
            bad = 1;
            break;
        }
        if (OSMesaGetCurrentContext() != ctx) {
            fprintf(stderr, "thread %d: OSMesaGetCurrentContext() is not this thread's context\n", id);
            bad = 1;
        }
        glViewport(0, 0, W, H);
        glClearColor(0.f, 0.f, 0.f, 1.f);
        glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);
        /* full-screen quad in this thread's color */
        glColor3ub(r, g, b);
        glBegin(GL_QUADS);
        glVertex2f(-1.f, -1.f);
        glVertex2f(1.f, -1.f);
        glVertex2f(1.f, 1.f);
        glVertex2f(-1.f, 1.f);
        glEnd();
        glFinish();
        for (i = 0; i < W * H; i++) {
            if (buf[4 * i] != r || buf[4 * i + 1] != g || buf[4 * i + 2] != b) {
                fprintf(stderr, "thread %d, iteration %d: pixel %d is (%d,%d,%d), expected (%d,%d,%d)\n",
                        id, it, i, buf[4 * i], buf[4 * i + 1], buf[4 * i + 2], r, g, b);
                bad = 1;
                break;
            }
        }
        OSMesaMakeCurrent(NULL, NULL, 0, 0, 0); /* release the context */
    }
    OSMesaDestroyContext(ctx);
    free(buf);
    if (bad) {
        pthread_mutex_lock(&failures_mutex);
        failures++;
        pthread_mutex_unlock(&failures_mutex);
    }
    return NULL;
}

int main(int argc, char **argv)
{
    int nthreads = argc > 1 ? atoi(argv[1]) : 8;
    pthread_t *threads;
    int i;

    if (argc > 2)
        iterations = atoi(argv[2]);
    threads = malloc(nthreads * sizeof(pthread_t));
    for (i = 0; i < nthreads; i++)
        pthread_create(&threads[i], NULL, render, (void *)(long)i);
    for (i = 0; i < nthreads; i++)
        pthread_join(threads[i], NULL);
    printf("%d threads x %d iterations: %s (%d failing threads)\n", nthreads, iterations,
           failures ? "FAILED" : "OK", failures);
    free(threads);
    return failures ? 1 : 0;
}
