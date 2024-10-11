#!/usr/bin/env python3
"""
"""
import jinja2
@jinja2.pass_environment
def do_groovy(env, data, skip_list_wrap=False):
    list_format="[{}]"
    if skip_list_wrap:
        list_format="{}"
    if isinstance(data, str):
        return '"{}"'.format(data.replace('"', '\"'))
    elif isinstance(data, list) or isinstance(data, tuple):
        _data = [do_groovy(env, d) for d in data]
        return list_format.format(", ".join(_data))
    elif isinstance(data, dict):
        _data = ["{}: {}".format(key, do_groovy(env, value)) for key, value in data.items()]
        return "[{}]".format(", ".join(_data))
    elif isinstance(data, bool):
        return 'true' if data else 'false'
    else:
        raise Exception("Unknown data type: '{}'".format(type(data)))
FILTERS = {
    "to_groovy": do_groovy,
}
