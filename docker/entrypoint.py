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
# Author: Chris Williams <chrisw@diosix.org>
#

import os
import sys

from flask import Flask

# the paths to load the Cargo config and select the diosix directory are derived from the Dockerfile
# this python isn't the most elegant -- feel free to fix up and send a pull request

if __name__ == "__main__":
    if not os.environ.get('K_SERVICE'):
        print('Running locally')
        os.system('. $HOME/.cargo/env && cd /diosix && {}'.format(' '.join(sys.argv[1:])))
    else:
        print('Running HTTP service {} {} {} for Google Cloud', os.environ.get('K_SERVICE'), os.environ.get('K_REVISION'), os.environ.get('K_CONFIGURATION'))
        app = Flask(__name__)
        @app.route('/')
        def ContainerService():
            return 'Container built. Use docker images and docker run in the Google Cloud shell to run this container.\n'
        app.run(debug=True,host='0.0.0.0',port=int(os.environ.get('PORT', 8080)))
