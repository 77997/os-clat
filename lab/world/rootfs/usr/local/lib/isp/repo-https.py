#!/usr/bin/env python3
"""repo-https.py ADDRESS DIRECTORY PEMFILE: serve DIRECTORY over HTTPS on [ADDRESS]:443.

The lab's stand-in for the GitHub Pages site of the os-clat package repository (isp-repo.service).
PEMFILE holds the certificate and its key. Every request is logged to stderr, so the journal of the
unit shows what the router fetched.
"""
import http.server
import socket
import ssl
import sys

ADDRESS, DIRECTORY, PEMFILE = sys.argv[1:4]


class Handler(http.server.SimpleHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=DIRECTORY, **kwargs)


class Server(http.server.ThreadingHTTPServer):
    address_family = socket.AF_INET6


context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
context.load_cert_chain(PEMFILE)
httpd = Server((ADDRESS, 443), Handler)
# the handshake runs in the thread of the request, so one silent client cannot block the others
httpd.socket = context.wrap_socket(httpd.socket, server_side=True, do_handshake_on_connect=False)
httpd.serve_forever()
