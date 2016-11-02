import array
import numbers
cimport cython
from cpython cimport array
from libc.stdint cimport uint8_t

cimport _heatshrink


MIN_WINDOW_SZ2 = _heatshrink.HEATSHRINK_MIN_WINDOW_BITS
MAX_WINDOW_SZ2 = _heatshrink.HEATSHRINK_MAX_WINDOW_BITS
DEFAULT_WINDOW_SZ2 = 11

MIN_LOOKAHEAD_SZ2 = _heatshrink.HEATSHRINK_MIN_LOOKAHEAD_BITS
DEFAULT_LOOKAHEAD_SZ2 = 4

DEFAULT_INPUT_BUFFER_SIZE = 2048


def _validate_bounds(val, name, min=None, max=None):
    """
    Ensure that `val` is larger than `min` and smaller than `max`.

    Throws `ValueError` if constraints are not met or
    if both `min` and `max` are None.
    Throws `TypeError` if `val` is not a number.
    """
    if min is None and max is None:
        raise ValueError("Expecting either a min or max parameter")

    if not isinstance(val, numbers.Number):
        msg = 'Expected number, got {}'
        raise TypeError(msg.format(val.__class__.__name__))

    if min and val < min:
        msg = "{} must be > {}".format(name, min)
    elif max and val > max:
        msg = "{} must be < {}".format(name, max)
    else:
        msg = ''

    if msg:
        raise ValueError(msg)
    return val


cdef class Writer:
    """Thin wrapper around heatshrink_encoder"""
    cdef _heatshrink.heatshrink_encoder *_hse

    def __cinit__(self, window_sz2, lookahead_sz2):
        _validate_bounds(window_sz2, name='window_sz2',
                        min=MIN_WINDOW_SZ2, max=MAX_WINDOW_SZ2)
        _validate_bounds(lookahead_sz2, name='lookahead_sz2',
                        min=MIN_LOOKAHEAD_SZ2, max=window_sz2)

        self._hse = _heatshrink.heatshrink_encoder_alloc(window_sz2, lookahead_sz2)
        if self._hse is NULL:
            raise MemoryError

    def __dealloc__(self):
        if self._hse is not NULL:
            _heatshrink.heatshrink_encoder_free(self._hse)

    @property
    def max_output_size(self):
        return 1 << self._hse.window_sz2

    cdef _heatshrink.HSE_sink_res sink(self,
                                        uint8_t *in_buf,
                                        size_t in_buf_size,
                                        size_t *sink_size) nogil:
        return _heatshrink.heatshrink_encoder_sink(
            self._hse,
            in_buf,
            in_buf_size,
            sink_size
        )

    cdef _heatshrink.HSE_poll_res poll(self,
                                        uint8_t *out_buf,
                                        size_t out_buf_size,
                                        size_t *poll_size) nogil:
        return _heatshrink.heatshrink_encoder_poll(
            self._hse,
            out_buf,
            out_buf_size,
            poll_size
        )

    def is_poll_empty(self, _heatshrink.HSE_poll_res res):
        return res == _heatshrink.HSE_POLL_EMPTY

    cdef _heatshrink.HSE_finish_res finish(self):
        return _heatshrink.heatshrink_encoder_finish(self._hse)

    def is_finished(self, _heatshrink.HSE_finish_res res):
        return res == _heatshrink.HSE_FINISH_DONE


cdef class Reader:
    """Thin wrapper around heatshrink_decoder"""
    cdef _heatshrink.heatshrink_decoder *_hsd

    def __cinit__(self, input_buffer_size, window_sz2, lookahead_sz2):
        _validate_bounds(input_buffer_size, name='input_buffer_size', min=0)
        _validate_bounds(window_sz2, name='window_sz2',
                        min=MIN_WINDOW_SZ2, max=MAX_WINDOW_SZ2)
        _validate_bounds(lookahead_sz2, name='lookahead_sz2',
                        min=MIN_LOOKAHEAD_SZ2, max=window_sz2)

        self._hsd = _heatshrink.heatshrink_decoder_alloc(
            input_buffer_size, window_sz2, lookahead_sz2)
        if self._hsd is NULL:
            raise MemoryError

    def __dealloc__(self):
        if self._hsd is not NULL:
            _heatshrink.heatshrink_decoder_free(self._hsd)

    @property
    def max_output_size(self):
        return 1 << self._hsd.window_sz2

    cdef _heatshrink.HSD_sink_res sink(self,
                                       uint8_t *in_buf,
                                       size_t in_buf_size,
                                       size_t *sink_size) nogil:
        return _heatshrink.heatshrink_decoder_sink(
            self._hsd,
            in_buf,
            in_buf_size,
            sink_size
        )

    cdef _heatshrink.HSD_poll_res poll(self,
                                       uint8_t *out_buf,
                                       size_t out_buf_size,
                                       size_t *poll_size) nogil:
        return _heatshrink.heatshrink_decoder_poll(
            self._hsd,
            out_buf,
            out_buf_size,
            poll_size
        )

    def is_poll_empty(self, _heatshrink.HSD_poll_res res):
        return res == _heatshrink.HSDR_POLL_EMPTY

    cdef _heatshrink.HSD_finish_res finish(self):
        return _heatshrink.heatshrink_decoder_finish(self._hsd)

    def is_finished(self, _heatshrink.HSD_finish_res res):
        return res == _heatshrink.HSDR_FINISH_DONE


def sink(encoder, array.array in_buf, size_t offset=0):
    """
    Sink input in to the encoder with an optional N byte `offset`.
    """
    res, sink_size = encoder.sink(&in_buf.data.as_uchars[offset],
                                  len(in_buf) - offset)
    if res < 0:
        raise RuntimeError('Sink failed.')

    return sink_size


def poll(encoder):
    """
    Poll output from an encoder/decoder.
    Returns a tuple containing the poll output buffer
    and a boolean indicating if polling is finished.
    """
    cdef array.array out_buf = array.array('B', [])
    # Resize to a decent length
    array.resize(out_buf, encoder.max_output_size)

    res, poll_size = encoder.poll(out_buf.data.as_uchars, len(out_buf))
    if res < 0:
        raise RuntimeError('Polling failed.')

    # Resize to drop unused elements
    array.resize(out_buf, poll_size)

    done = encoder.is_poll_empty(res)
    return (out_buf, done)


def finish(encoder):
    """
    Notifies the encoder that the input stream is finished.
    Returns `False` if there is more ouput to be processed,
    meaning that poll should be called again.
    """
    res = encoder.finish()
    if res < 0:
        raise RuntimeError("Finish failed.")
    return encoder.is_finished(res)


# TODO: Use a better name
class Encoder(object):
    def __init__(self, encoder):
        self._encoder = encoder

    def _drain(self):
        """Empty data from the encoder state machine."""
        while True:
            polled, done = poll(self._encoder)

            yield polled

            if done:
                raise StopIteration

    def fill(self, buf):
        """
        Fill the encoder state machine with a buffer.
        """
        if isinstance(buf, (unicode, memoryview)):
            msg = "Cannot fill encoder with type '{.__name__}'"
            raise TypeError(msg.format(buf.__class__))

        # Convert input to a byte representation
        cdef array.array in_buf  = array.array('B', buf)
        cdef array.array out_buf = array.array('B', [])

        cdef size_t total_sunk = 0

        while total_sunk < len(in_buf):
            total_sunk += sink(self._encoder, in_buf, offset=total_sunk)

            # Clear state machine
            for data in self._drain():
                pass
                # out_buf.extend(data)

        # return out_buf.tostring()
        return None

    # TODO: Find a way to handle that there may be left over
    # TODO: data in the state machine.
    def finish(self):
        cdef array.array out_buf = array.array('B', [])

        while True:
            if finish(self._encoder):
                break

            for data in self._drain():
                out_buf.extend(data)

        return out_buf.tostring()


cdef encode_impl(encoder, buf):
    """Encode iterable `buf` into an array of bytes."""
    encoder = Encoder(encoder)

    encoded = encoder.fill(buf)
    # Add any extra data remaining in the state machine
    encoded += encoder.finish()

    return encoded


def encode(buf, **kwargs):
    """
    Encode iterable `buf` in to a byte string.

    Keyword arguments:
        window_sz2 (int): Determines how far back in the input can be
            searched for repeated patterns. Defaults to `DEFAULT_WINDOW_SZ2`.
            Allowed values are between. `MIN_WINDOW_SZ2` and `MAX_WINDOW_SZ2`.
        lookahead_sz2 (int): Determines the max length for repeated
            patterns that are found. Defaults to `DEFAULT_LOOKAHEAD_SZ2`.
            Allowed values are between `MIN_LOOKAHEAD_SZ2` and the
            value set for `window_sz2`.

    Returns:
        str or bytes: A byte string of encoded contents.
            str is used for Python 2 and bytes for Python 3.

    Raises:
        ValueError: If `window_sz2` or `lookahead_sz2` are outside their
            defined ranges.
        TypeError: If `window_sz2`, `lookahead_sz2` are not valid numbers and
            if `buf` is not a valid iterable.
        RuntimeError: Thrown if internal polling or sinking of the
            encoder/decoder fails.
    """
    encode_params = {
        'window_sz2': DEFAULT_WINDOW_SZ2,
        'lookahead_sz2': DEFAULT_LOOKAHEAD_SZ2,
    }
    encode_params.update(kwargs)

    encoder = Writer(encode_params['window_sz2'],
                      encode_params['lookahead_sz2'])
    return encode_impl(encoder, buf)


def decode(buf, **kwargs):
    """
    Decode iterable `buf` in to a byte string.

    Keyword arguments:
        input_buffer_size (int): How large an input buffer to use for the decoder.
            This impacts how much work the decoder can do in a single step,
            a larger buffer will use more memory.
        window_sz2 (int): Determines how far back in the input can be
            searched for repeated patterns. Defaults to `DEFAULT_WINDOW_SZ2`.
            Allowed values are between. `MIN_WINDOW_SZ2` and `MAX_WINDOW_SZ2`.
        lookahead_sz2 (int): Determines the max length for repeated
            patterns that are found. Defaults to `DEFAULT_LOOKAHEAD_SZ2`.
            Allowed values are between `MIN_LOOKAHEAD_SZ2` and the
            value set for `window_sz2`.

    Returns:
        str or bytes: A byte string of decoded contents.
            str is used for Python 2 and bytes for Python 3.

    Raises:
        ValueError: If `input_buffer_size`, `window_sz2` or `lookahead_sz2` are
            outside their defined ranges.
        TypeError: If `input_buffer_size`, `window_sz2` or `lookahead_sz2` are
            not valid numbers and if `buf` is not a valid iterable.
        RuntimeError: Thrown if internal polling or sinking of the
            encoder/decoder fails.
    """
    decode_params = {
        'input_buffer_size': DEFAULT_INPUT_BUFFER_SIZE,
        'window_sz2': DEFAULT_WINDOW_SZ2,
        'lookahead_sz2': DEFAULT_LOOKAHEAD_SZ2,
    }
    decode_params.update(kwargs)

    encoder = Reader(decode_params['input_buffer_size'],
                      decode_params['window_sz2'],
                      decode_params['lookahead_sz2'])
    return encode_impl(encoder, buf)

