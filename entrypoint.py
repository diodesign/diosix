#!/usr/bin/python3
#
# Define containerized environment for running Diosix on Qemu
#
# On Google Cloud Run: Creates HTTP server on port 8080
# or whatever was specified using the PORT system variable.
# Outputs via the HTTP port. This requires K_SERVICE to be set.
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

if __name__ == "__main__":
    if (os.environ.get('K_SERVICE')) != '':
        print('Running HTTP service for Google Cloud')
        # app = Flask(__name__)
        # @app.route('/')
        # def ContainerService():
        #   return 'Container built. Use docker images and docker run in the Google Cloud shell to run this container.\n'
        # app.run(debug=True,host='0.0.0.0',port=int(os.environ.get('PORT', 8080)))
    else:
        print('Running locally')
        # stream = os.popen('. $HOME/.cargo/env && cd /build/diosix && {}'.format(' '.join(sys.argv[1:])))
        # output = stream.read()
        # output
