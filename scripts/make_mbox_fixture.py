#!/usr/bin/env python3
"""Writes a small Netscape Communicator 4.x style mail folder for the tests.

Every folder is an mbox file, `Name.sbd/` holds its subfolders and `.snm` files are
Netscape's summary indexes (junk here: the reader must ignore them). The messages
cover the cases old archives contain: CRLF and CR-only line endings, quoted-printable
and base64, RFC 2047 headers, raw 8-bit headers, deleted-but-not-compacted messages,
"From " lines inside message text, multipart/alternative, uuencode and forwarded
messages.

    python3 scripts/make_mbox_fixture.py Tests/PSTKitTests/Fixtures/netscape
"""
import base64
import os
import shutil
import sys


def mbox(messages, eol=b"\r\n"):
    out = b""
    for status, date, msg in messages:
        lines = [b"From - " + date.encode(), b"X-Mozilla-Status: " + status.encode(), b"X-Mozilla-Status2: 00000000"]
        lines += msg.split(b"\n")
        out += eol.join(lines) + eol + eol
    return out


INBOX = [
    ("0001", "Thu Nov 04 10:15:00 1999", b"""Return-Path: <jan@example.nl>
Message-ID: <38214A1B.1@example.nl>
Date: Thu, 04 Nov 1999 10:14:51 +0100
From: Jan de Vries <jan@example.nl>
To: mvberkum@example.nl, "Berg, Piet" <piet@example.nl>
Subject: =?iso-8859-1?Q?Caf=E9_morgen?=
Mime-Version: 1.0
Content-Type: text/plain; charset=iso-8859-1
Content-Transfer-Encoding: quoted-printable

Zullen we morgen naar het caf=E9 gaan?
Groet, Jan"""),
    ("0000", "Wed Nov 03 09:00:00 1999", b"""Message-ID: <38214A1B.2@example.com>
Date: Wed, 3 Nov 1999 08:59:10 -0500
From: anna@example.com (Anna Smith)
To: mvberkum@example.nl
Subject: Report with attachment
X-Priority: 1 (Highest)
Content-Type: multipart/mixed; boundary="------------ABC123"

This is a multi-part message in MIME format.
--------------ABC123
Content-Type: text/plain; charset=us-ascii
Content-Transfer-Encoding: 7bit

Here is the report.
>From the start it was clear.
From here on it gets better, at 10:30 or so.
Bye
--------------ABC123
Content-Type: text/plain; charset=us-ascii; name="hello.txt"
Content-Transfer-Encoding: base64
Content-Disposition: attachment; filename="hello.txt"

""" + base64.encodebytes(b"Hello, world!\n").strip() + b"""
--------------ABC123--
"""),
    ("0009", "Tue Nov 02 12:00:00 1999", b"""Date: Tue, 2 Nov 1999 12:00:00 +0100
From: spam@example.org
To: mvberkum@example.nl
Subject: Deleted message

This one was deleted in Netscape but the folder was never compacted."""),
    ("0001", "Mon Nov 01 08:00:00 1999", b"""Date: 1 Nov 99 07:59 MET
From: Ren\xe9 Janssen <rene@example.nl>
To: mvberkum@example.nl
Subject: HTML mail
MIME-Version: 1.0
Content-Type: multipart/alternative; boundary="alt"

--alt
Content-Type: text/plain; charset=iso-8859-1
Content-Transfer-Encoding: 8bit

Dit is HTML-mail van Ren\xe9.
--alt
Content-Type: text/html; charset=iso-8859-1
Content-Transfer-Encoding: 8bit

<html><body><b>Dit is HTML-mail van Ren\xe9.</b></body></html>
--alt--
"""),
]

UU = b"begin 644 data.bin\n" + b"".join(
    bytes([32 + len(chunk)]) + b"".join(
        bytes([(((v >> s) & 63) or 64) + 32 for s in (18, 12, 6, 0)])
        for v in [int.from_bytes((chunk + b"\0\0")[i:i + 3], "big") for i in range(0, len(chunk), 3)]
    ) + b"\n"
    for chunk in [bytes(range(45)), bytes(range(45, 60))]
) + b"`\nend"

SENT = [
    ("0001", "Mon Oct 18 14:00:00 1999", b"""Date: Mon, 18 Oct 1999 14:00:00 +0200
From: Martijn <mvberkum@example.nl>
To: anna@example.com
Subject: Old style attachment

See the file below.

""" + UU + b"""

Regards"""),
    ("0001", "Tue Oct 19 15:00:00 1999", b"""Date: Tue, 19 Oct 1999 15:00:00 +0200
From: Martijn <mvberkum@example.nl>
To: piet@example.nl
Subject: Fwd: Report with attachment
Content-Type: multipart/mixed; boundary="fwd"

--fwd
Content-Type: text/plain

Forwarded below.
--fwd
Content-Type: message/rfc822

From: anna@example.com (Anna Smith)
Subject: Original report
Date: Wed, 13 Oct 1999 08:59:10 -0500

The original text.
--fwd--
"""),
]

PROJECT = [
    ("0001", "Fri Jul 30 11:00:00 1999", b"""Date: Fri, 30 Jul 1999 11:00:00 +0200
From: klant@example.com
To: mvberkum@example.nl
Subject: Project kickoff

Saved by a classic Mac OS mail program: CR line endings."""),
]


def main(target):
    if os.path.exists(target):
        shutil.rmtree(target)
    os.makedirs(os.path.join(target, "Projecten.sbd"))

    def write(name, data):
        with open(os.path.join(target, name), "wb") as f:
            f.write(data)

    write("Inbox", mbox(INBOX))
    write("Inbox.snm", bytes(range(256)))
    write("Sent", mbox(SENT, eol=b"\n"))
    write("Sent.snm", b"\x00" * 64)
    write("Templates", b"")
    write("Projecten", b"")
    write("Projecten.snm", b"\x00" * 16)
    write(os.path.join("Projecten.sbd", "Klant A"), mbox(PROJECT, eol=b"\r"))
    write("popstate.dat", b"# Netscape POP3 State File\n")
    write("rules.dat", b"version=\"8\"\n")


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "Tests/PSTKitTests/Fixtures/netscape")
