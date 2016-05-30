/* FIXME: This isn't cross platform */
#include <Python/Python.h>


/* FIXME: Add to include path */
#include "../heatshrink/heatshrink_encoder.h"
#include "../heatshrink/heatshrink_decoder.h"

#include "dynamic_arrays.h"

/* Redefine HEATSHRINK_DEBUGGING_LOGS to work with NDEBUG */
#undef HEATSHRINK_DEBUGGING_LOGS
#ifdef NDEBUG
#define HEATSHRINK_DEBUGGING_LOGS 0

#define log_debug(msg, ...) ((void) 0) /* Do nothing */
#else
#define HEATSHRINK_DEBUGGING_LOGS 1

#define log_debug(msg, ...)																							\
		fprintf(stdout, "[DEBUG] (%s:%d) " msg "\n", __FILE__, __LINE__, ##__VA_ARGS__)
#endif /* NDEBUG */


#define DEFAULT_HEATSHRINK_WINDOW_SZ2 11
#define DEFAULT_HEATSHRINK_LOOKAHEAD_SZ2 4

/************************************************************
 * Encoding
 ************************************************************/
typedef enum {
		PYHS_OK,
		PYHS_FAILED_SINK=-1,
		PYHS_FAILED_POLL=-2,
		PYHS_FAILED_FINISH=-3,
} PyHS_encode_res;

static PyHS_encode_res
_encode_to_out(heatshrink_encoder *hse, uint8_t *in_buf, size_t in_size,
							 UInt8Array *out_arr)
{
		HSE_sink_res sink_res;
		HSE_poll_res poll_res;
		HSE_finish_res finish_res;
		size_t total_sunk_size = 0;

		size_t out_size = 4096;
		uint8_t out_buf[out_size];
		while(1) {
				size_t sunk_size;
				size_t poll_size;

				/* Sink */
				if(total_sunk_size < in_size) {
						sink_res = heatshrink_encoder_sink(hse,
																							 &in_buf[total_sunk_size],
																							 in_size - total_sunk_size,
																							 &sunk_size);
						if(sink_res < 0) {
								return PYHS_FAILED_SINK;
						}
						total_sunk_size += sunk_size;
				}

				do
				{
						/* Poll input result */
						poll_res = heatshrink_encoder_poll(hse, out_buf, out_size, &poll_size);
						if(poll_res < 0) {
								return PYHS_FAILED_POLL;
						}
						uint8_array_insert(out_arr, out_buf, poll_size);
				} while(poll_res == HSER_POLL_MORE);

				if(total_sunk_size >= in_size) {
						/* Ensure all input is processed */
						finish_res = heatshrink_encoder_finish(hse);
						/* We can't use a switch because we need break to refer to the while loop */
						if(finish_res == HSER_FINISH_DONE) {
								log_debug("HSER_FINISH_DONE, encoding finished");
								break;
						} else if(finish_res == HSER_FINISH_MORE) {
								log_debug("HSER_FINISH_MORE, reruning poll");
								continue;
						} else {
								log_debug("encoder finish failed");
								return PYHS_FAILED_FINISH;
						}
				}
		}

		return PYHS_OK;
}

static PyObject *
PyHS_encode(PyObject *self, PyObject *args)
{
		char *in_buf = NULL;
		int in_size;
		if(!PyArg_ParseTuple(args, "t#", &in_buf, &in_size))
				return NULL;

		heatshrink_encoder *hse = heatshrink_encoder_alloc(
				DEFAULT_HEATSHRINK_WINDOW_SZ2,
				DEFAULT_HEATSHRINK_LOOKAHEAD_SZ2);
		if(hse == NULL) {
				PyErr_SetString(PyExc_MemoryError, "failed to allocate encoder");
				return NULL;
		}

		/* Initialize output buffer */
		UInt8Array *out_arr = uint8_array_create(1024);
		/* FIXME: Safely convert char * to uint8_t * (aka unsigned char*) */
		PyHS_encode_res eres = _encode_to_out(hse, in_buf, in_size, out_arr);

		log_debug("Wrote %zd bytes to out_arr", uint8_array_count(out_arr));
		log_debug("Capacity %zd bytes of out_arr", uint8_array_capacity(out_arr));

		heatshrink_encoder_free(hse);
		uint8_array_free(out_arr);

		switch(eres) {
		case PYHS_FAILED_SINK:
				PyErr_SetString(PyExc_RuntimeError, "encoder sink failed");
				return NULL;
		case PYHS_FAILED_POLL:
				PyErr_SetString(PyExc_RuntimeError, "encoder poll failed");
				return NULL;
		case PYHS_FAILED_FINISH:
				PyErr_SetString(PyExc_RuntimeError, "encoder finish failed");
				return NULL;
		default:
				/* TODO: Use PyString_Encode */
				return PyInt_FromSize_t(uint8_array_count(out_arr));
		}
}

/************************************************************
 * TODO: Decoder
 ************************************************************/

static PyObject *
PyHS_decode(PyObject *self, PyObject *args)
{
		PyErr_SetString(PyExc_NotImplementedError, "not implemented");
		return NULL;
}

/************************************************************
 * Module definition
 ************************************************************/
static PyMethodDef Heatshrink_methods [] = {
		{"encode", PyHS_encode, METH_VARARGS,
		 "Encode buffer."},
		{"decode", PyHS_decode, METH_VARARGS,
		 "Decode buffer."},
		{NULL, NULL, 0, NULL} // Sentinel
};

/************************************************************
 * Initialization
 ************************************************************/
#ifndef PyMODINIT_FUNC	/* declarations for DLL import/export */
#define PyMODINIT_FUNC void
#endif

PyMODINIT_FUNC
initheatshrink(void)
{
		(void) Py_InitModule("heatshrink", Heatshrink_methods);
}
