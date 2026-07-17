/*
 * Native libFuzzer driver that embeds CPython to fuzz pyshp's pure-Python
 * shapefile reader.
 *
 * Why a native ELF instead of a bare `python3 harness.py` Atheris target:
 * the Mayhem commit-image contract requires every target to be an ELF binary
 * carrying DWARF (< 4) debug info that libFuzzer drives (fuzz-smoke + the DWARF
 * gate). So we compile a real libFuzzer ELF that embeds the interpreter and
 * dispatches each input into `fuzz_shapefile.TestOneInput`. The fuzzed code is
 * still 100% the pure-Python `shapefile.Reader` parser.
 *
 * Built twice by mayhem/build.sh:
 *   - linked with $LIB_FUZZING_ENGINE  -> /mayhem/fuzz_shp            (the fuzzer)
 *   - linked with $STANDALONE_FUZZ_MAIN -> /mayhem/fuzz_shp-standalone (run-once repro)
 *
 * PYHOME / PYTHONPATH are baked in at compile time (-DPYSHP_*) so the binary
 * locates the interpreter and the harness/library sources at a fixed location
 * regardless of $HOME (needed for the air-gapped PATCH re-run).
 */
#include <Python.h>

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* Compile-time configuration (set with -D in build.sh). */
#ifndef PYSHP_MODULE
#define PYSHP_MODULE "fuzz_shapefile"
#endif
#ifndef PYSHP_FUNC
#define PYSHP_FUNC "TestOneInput"
#endif

static PyObject *g_test_one_input = NULL;

static void die_py(const char *what) {
    fprintf(stderr, "fuzz_shp: fatal: %s\n", what);
    if (PyErr_Occurred()) {
        PyErr_Print();
    }
    fflush(stderr);
    abort();
}

int LLVMFuzzerInitialize(int *argc, char ***argv) {
    (void)argc;
    (void)argv;

    PyConfig config;
    /* Python (not Isolated) config: use the system interpreter's compiled-in
     * paths so the stdlib resolves; we only ADD our dirs to sys.path below. */
    PyConfig_InitPythonConfig(&config);

    /* Don't let the interpreter install its own fault handlers / signal
     * handlers — libFuzzer/ASan own those and must see the real crash. */
    config.install_signal_handlers = 0;
    config.faulthandler = 0;
    config.parse_argv = 0;
    config.write_bytecode = 0;

    PyStatus status = Py_InitializeFromConfig(&config);
    PyConfig_Clear(&config);
    if (PyStatus_Exception(status)) {
        fprintf(stderr, "fuzz_shp: Py_InitializeFromConfig failed\n");
        abort();
    }

    /* Prepend the harness dir + the pyshp source dir to sys.path. */
#ifdef PYSHP_PATHS
    {
        const char *paths = PYSHP_PATHS; /* colon-separated */
        PyObject *sys_path = PySys_GetObject("path"); /* borrowed */
        if (!sys_path) {
            die_py("sys.path not available");
        }
        char *dup = strdup(paths);
        if (!dup) {
            die_py("strdup");
        }
        char *save = NULL;
        for (char *tok = strtok_r(dup, ":", &save); tok;
             tok = strtok_r(NULL, ":", &save)) {
            PyObject *p = PyUnicode_FromString(tok);
            if (!p) {
                die_py("PyUnicode_FromString(path)");
            }
            if (PyList_Insert(sys_path, 0, p) != 0) {
                die_py("PyList_Insert(sys.path)");
            }
            Py_DECREF(p);
        }
        free(dup);
    }
#endif

    PyObject *mod = PyImport_ImportModule(PYSHP_MODULE);
    if (!mod) {
        die_py("import harness module (" PYSHP_MODULE ")");
    }
    g_test_one_input = PyObject_GetAttrString(mod, PYSHP_FUNC);
    Py_DECREF(mod);
    if (!g_test_one_input || !PyCallable_Check(g_test_one_input)) {
        die_py("lookup " PYSHP_FUNC);
    }
    return 0;
}

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
    if (g_test_one_input == NULL) {
        /* The standalone driver calls TestOneInput without first calling
         * LLVMFuzzerInitialize, so initialize lazily. */
        LLVMFuzzerInitialize(NULL, NULL);
    }

    PyGILState_STATE gil = PyGILState_Ensure();

    PyObject *arg = PyBytes_FromStringAndSize((const char *)data, (Py_ssize_t)size);
    if (!arg) {
        PyErr_Clear();
        PyGILState_Release(gil);
        return 0;
    }

    PyObject *res = PyObject_CallFunctionObjArgs(g_test_one_input, arg, NULL);
    Py_DECREF(arg);

    if (res == NULL) {
        /* An exception the harness did NOT expect escaped TestOneInput — treat
         * it as a finding (libFuzzer/standalone will record the abort). */
        die_py("unhandled exception in " PYSHP_FUNC);
    }
    Py_DECREF(res);

    PyGILState_Release(gil);
    return 0;
}
