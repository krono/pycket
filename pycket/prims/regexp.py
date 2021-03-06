from pycket.prims.expose import (unsafe, default, expose, expose_val,
                                 procedure, make_call_method, define_nyi)
from pycket import values, values_string, values_regex
from pycket.error import SchemeException

from rpython.rlib import jit
import sys

@expose("regexp", [values_string.W_String])
def regrexp(w_str):
    return values_regex.W_Regexp(w_str.as_str_utf8())

@expose("pregexp", [values_string.W_String])
def pregrexp(w_str):
    return values_regex.W_PRegexp(w_str.as_str_utf8())

@expose("byte-regexp", [values.W_Bytes])
def byte_regrexp(w_str):
    return values_regex.W_ByteRegexp(w_str.as_str())

@expose("byte-pregexp", [values.W_Bytes])
def byte_pregrexp(w_str):
    return values_regex.W_BytePRegexp(w_str.as_str())


@expose("regexp-match", [values.W_Object, values.W_Object])
@jit.unroll_safe
def regexp_match(w_re, w_str):
    result = match(w_re, w_str)
    if result is None:
        return values.w_false
    elif (isinstance(w_str, values_string.W_String) or \
          isinstance(w_str, values.W_StringInputPort)) \
        and \
         (isinstance(w_re, values_regex.W_PRegexp) or \
          isinstance(w_re, values_regex.W_Regexp) or \
          isinstance(w_re, values_string.W_String)):
        return values.to_list([values_string.W_String.fromascii(r)
                               if r else values.w_false
                               for r in result])
    else:
        return values.to_list([values.W_Bytes.from_string(r)
                               if r else values.w_false
                               for r in result])

def promote_to_regexp(w_re):
    if isinstance(w_re, values_string.W_String):
        return values_regex.W_Regexp(w_re.as_str_ascii()) # XXX for now
    if isinstance(w_re, values.W_Bytes):
        return values_regex.W_Regexp(w_re.as_str())
    if isinstance(w_re, values_regex.W_AnyRegexp):
        return w_re
    raise SchemeException("regexp-match: unknown kind of regexp")

def match(w_re, w_str):
    w_re = promote_to_regexp(w_re)
    if isinstance(w_str, values_string.W_String):
        s = w_str.as_str_ascii() # XXX for now
        result = w_re.match_string(s)
        return result
    if isinstance(w_str, values.W_Bytes):
        result = w_re.match_string(w_str.as_str())
        return result
    if isinstance(w_str, values.W_InputPort):
        result = w_re.match_port(w_str)
        return result
    raise SchemeException("regexp-match: can't deal with this type")

def match_positions(w_re, w_str, start=0, end=sys.maxint):
    w_re = promote_to_regexp(w_re)
    if isinstance(w_str, values_string.W_String):
        s = w_str.as_str_ascii() # XXX for now
        result = w_re.match_string_positions(s, start, end)
        return result
    if isinstance(w_str, values.W_Bytes):
        result = w_re.match_string_positions(w_str.as_str(), start, end)
        return result
    if isinstance(w_str, values.W_InputPort):
        result = w_re.match_port_positions(w_str)
        return result
    raise SchemeException("regexp-match-positions: can't deal with this type")

def make_match_list(lst):
    assert lst
    acc = values.w_null
    end = 0
    for start, end in reversed(lst):
        s    = values.W_Fixnum(start)
        e    = values.W_Fixnum(end)
        elem = values.W_Cons.make(s, e)
        acc  = values.W_Cons.make(elem, acc)
    return acc, end

EMPTY_BYTES = values.W_Bytes.from_string("")
NO_MATCH = values.Values.make([values.w_false, values.w_false])
ZERO = values.W_Fixnum.make(0)
ONE  = values.W_Fixnum.make(1)

RMP_ARGS = [
    values.W_Object,
    values.W_Object,
    default(values.W_Fixnum, ZERO),
    default(values.W_Object, values.w_false),
    default(values.W_Object, values.w_false),
    default(values.W_Bytes, EMPTY_BYTES)]

@expose("regexp-match-positions", RMP_ARGS)
@jit.unroll_safe
def rmp(pat, input, inp_start, inp_end, output_port, prefix):
    start = inp_start.value
    if inp_end is values.w_false:
        end = sys.maxint
    elif isinstance(inp_end, values.W_Fixnum):
        end = inp_end.value
    else:
        raise SchemeException("regexp-match-positions: expected fixnum or #f for argument 3")
    assert output_port is values.w_false, "output port not supported yet"
    matches = match_positions(pat, input)
    if matches is None:
        return values.w_false
    lst, _ = make_match_list(matches)
    return lst

RMPE_ARGS = [
    values.W_Object,
    values.W_Object,
    default(values.W_Fixnum, ZERO),
    default(values.W_Object, values.w_false),
    default(values.W_Object, values.w_false),
    default(values.W_Bytes, EMPTY_BYTES),
    default(values.W_Fixnum, ONE)]

@expose("regexp-match-positions/end", RMPE_ARGS, simple=False)
@jit.unroll_safe
def rmpe(pat, input, inp_start, inp_end, output_port, prefix, count, env, cont):
    from pycket.interpreter import return_multi_vals

    start = inp_start.value
    if inp_end is values.w_false:
        end = sys.maxint
    elif isinstance(inp_end, values.W_Fixnum):
        end = inp_end.value
    else:
        raise SchemeException("regexp-match-positions/end: expected fixnum or #f for argument 3")

    assert output_port is values.w_false, "output port not supported yet"

    matches = match_positions(pat, input, start, end)
    if matches is None:
        return return_multi_vals(NO_MATCH, env, cont)

    acc, end = make_match_list(matches)

    length = count.value
    input_str = input.as_str_ascii()
    start = max(0, end - length)

    assert start >= 0 and end >= 0
    bytes = values.W_Bytes.from_string(input_str[start:end], immutable=False)
    result = values.Values.make([acc, bytes])
    return return_multi_vals(result, env, cont)

@expose("regexp-match?", [values.W_Object, values.W_Object])
def regexp_matchp(w_r, w_o):
    result = match(w_r, w_o)
    if result:
        return values.w_true
    else:
        return values.w_false

@expose("regexp-max-lookbehind", [values.W_Object])
def regexp_max_lookbehind(obj):
    if not isinstance(obj, values_regex.W_Regexp) and not isinstance(obj, values_regex.W_ByteRegexp):
        raise SchemeException("regexp-max-lookbehind: expected regexp or bytes-regexp")
    return values.W_Fixnum(1000)

# FIXME: implementation
define_nyi("regexp-replace", [values.W_Object, values.W_Object, values.W_Object,
                           default(values.W_Bytes, None)])
# def regexp_replace(pattern, input, insert, input_prefix):
#     raise NotImplementedError()
#     return input
