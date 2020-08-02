#!/usr/bin/python3
#
# Define containerized environment for running Diosix on Qemu
#
# On Google Cloud Run: Creates HTTP server on port 8080
# or whatever was specified using the PORT system variable.
# Use this to signal the build was successful and the container\
# can be run via the command line.
#
# On all other environments: Log to stdout
#
# syntax: entrypoint.py <command>
#
# Author: Chris Williams <diodesign@tuta.io>
#

import os
import sys

global command_result

from flask import Flask
app = Flask(__name__)

# for Google Cloud Run
@app.route('/')
def ContainerService():
    return 'Container built. Use docker images and docker run in the Google Cloud shell to run this container.\n'

if __name__ == "__main__":
    if (os.environ.get('K_SERVICE')) != '':
        app.run(debug=True,host='0.0.0.0',port=int(os.environ.get('PORT', 8080)))
    else:
        stream = os.popen('. $HOME/.cargo/env && cd /build/diosix && {}'.format(' '.join(sys.argv[1:])))
        output = stream.read()
        output
