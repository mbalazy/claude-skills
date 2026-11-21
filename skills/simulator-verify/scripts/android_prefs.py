#!/usr/bin/env python3
"""Read and rewrite ONE key of an Android SharedPreferences file without touching the rest.

  android_prefs.py get KEY < prefs.xml          # the string value, or nothing (exit 1)
  android_prefs.py set KEY VALUE < prefs.xml    # the whole file again with KEY = VALUE
  android_prefs.py unset KEY < prefs.xml        # the whole file again without KEY

React Native's debug builds read the Metro host from the `debug_http_host` string in
`shared_prefs/<package>_preferences.xml`. The same file holds the app's own keys (and
every library's that uses the default preferences), so it is read WHOLE, merged here on
the host and written back whole. A single `run-as ... cat F | ... > F` pipeline
truncates the file before it is read and loses every other key.

The text of every other entry is kept byte for byte: only the one element is removed
and, for `set`, a new one appended before `</map>`. Empty input = a new file.
"""
import re
import sys
from xml.sax.saxutils import escape, unescape

HEAD = "<?xml version='1.0' encoding='utf-8' standalone='yes' ?>\n"


def _element(key):
    # <string name="KEY">...</string> or <string name="KEY" /> (an empty string value).
    k = re.escape(escape(key, {'"': "&quot;"}))
    return re.compile(r'[ \t]*<string name="%s"(?: */>|>(.*?)</string>)[ \t]*\n?' % k, re.S)


def get(xml_text, key):
    m = _element(key).search(xml_text or "")
    if not m:
        return None
    return unescape(m.group(1) or "", {"&quot;": '"', "&apos;": "'"})


def without(xml_text, key):
    return _element(key).sub("", xml_text or "", count=0)


def put(xml_text, key, value):
    body = without(xml_text, key)
    line = '    <string name="%s">%s</string>\n' % (escape(key, {'"': "&quot;"}), escape(value))
    if not body.strip():
        return HEAD + "<map>\n" + line + "</map>\n"
    if re.search(r"<map\s*/>", body):
        return re.sub(r"<map\s*/>", "<map>\n" + line + "</map>", body, count=1)
    i = body.rfind("</map>")
    if i < 0:
        raise ValueError("not a SharedPreferences file (no </map>)")
    return body[:i] + line + body[i:]


def main(argv=None):
    argv = sys.argv[1:] if argv is None else argv
    if len(argv) < 2 or argv[0] not in ("get", "set", "unset") or (argv[0] == "set") != (len(argv) == 3):
        print(__doc__.strip().split("\n\n")[0], file=sys.stderr)
        return 2
    text = sys.stdin.read()
    if argv[0] == "get":
        v = get(text, argv[1])
        if v is None:
            return 1
        print(v)
        return 0
    try:
        sys.stdout.write(put(text, argv[1], argv[2]) if argv[0] == "set" else without(text, argv[1]))
    except ValueError as e:
        print("ERROR: %s" % e, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
