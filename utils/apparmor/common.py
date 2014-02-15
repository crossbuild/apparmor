# ------------------------------------------------------------------
#
#    Copyright (C) 2012 Canonical Ltd.
#    Copyright (C) 2013 Kshitij Gupta <kgupta8592@gmail.com>
#
#    This program is free software; you can redistribute it and/or
#    modify it under the terms of version 2 of the GNU General Public
#    License published by the Free Software Foundation.
#
# ------------------------------------------------------------------

from __future__ import print_function
import codecs
import collections
import glob
import logging
import os
import re
import subprocess
import sys
import termios
import tty

DEBUGGING = False


#
# Utility classes
#
class AppArmorException(Exception):
    '''This class represents AppArmor exceptions'''
    def __init__(self, value):
        self.value = value

    def __str__(self):
        return repr(self.value)

#
# Utility functions
#
def error(out, exit_code=1, do_exit=True):
    '''Print error message and exit'''
    try:
        print("ERROR: %s" % (out), file=sys.stderr)
    except IOError:
        pass

    if do_exit:
        sys.exit(exit_code)

def warn(out):
    '''Print warning message'''
    try:
        print("WARN: %s" % (out), file=sys.stderr)
    except IOError:
        pass

def msg(out, output=sys.stdout):
    '''Print message'''
    try:
        print("%s" % (out), file=output)
    except IOError:
        pass

def debug(out):
    '''Print debug message'''
    global DEBUGGING
    if DEBUGGING:
        try:
            print("DEBUG: %s" % (out), file=sys.stderr)
        except IOError:
            pass

def cmd(command):
    '''Try to execute the given command.'''
    debug(command)
    try:
        sp = subprocess.Popen(command, stdout=subprocess.PIPE,
                              stderr=subprocess.STDOUT)
    except OSError as ex:
        return [127, str(ex)]

    if sys.version_info[0] >= 3:
        out = sp.communicate()[0].decode('ascii', 'ignore')
    else:
        out = sp.communicate()[0]

    return [sp.returncode, out]


def cmd_pipe(command1, command2):
    '''Try to pipe command1 into command2.'''
    try:
        sp1 = subprocess.Popen(command1, stdout=subprocess.PIPE)
        sp2 = subprocess.Popen(command2, stdin=sp1.stdout)
    except OSError as ex:
        return [127, str(ex)]

    if sys.version_info[0] >= 3:
        out = sp2.communicate()[0].decode('ascii', 'ignore')
    else:
        out = sp2.communicate()[0]

    return [sp2.returncode, out]

def valid_path(path):
    '''Valid path'''
    # No relative paths
    m = "Invalid path: %s" % (path)
    if not path.startswith('/'):
        debug("%s (relative)" % (m))
        return False

    if '"' in path:  # We double quote elsewhere
        return False

    try:
        os.path.normpath(path)
    except Exception:
        debug("%s (could not normalize)" % (m))
        return False
    return True

def get_directory_contents(path):
    '''Find contents of the given directory'''
    if not valid_path(path):
        return None

    files = []
    for f in glob.glob(path + "/*"):
        files.append(f)

    files.sort()
    return files

def open_file_read(path, encoding='UTF-8'):
    '''Open specified file read-only'''
    try:
        orig = codecs.open(path, 'r', encoding)
    except Exception:
        raise

    return orig

def open_file_write(path):
    '''Open specified file in write/overwrite mode'''
    try:
        orig = codecs.open(path, 'w', 'UTF-8')
    except Exception:
        raise
    return orig

def readkey():
    '''Returns the pressed key'''
    fd = sys.stdin.fileno()
    old_settings = termios.tcgetattr(fd)
    try:
        tty.setraw(sys.stdin.fileno())
        ch = sys.stdin.read(1)
    finally:
        termios.tcsetattr(fd, termios.TCSADRAIN, old_settings)

    return ch

def hasher():
    '''A neat alternative to perl's hash reference'''
    # Creates a dictionary for any depth and returns empty dictionary otherwise
    return collections.defaultdict(hasher)

def convert_regexp(regexp):
    regex_paren = re.compile('^(.*){([^}]*)}(.*)$')
    regexp = regexp.strip()
    new_reg = re.sub(r'(?<!\\)(\.|\+|\$)', r'\\\1', regexp)

    while regex_paren.search(new_reg):
        match = regex_paren.search(new_reg).groups()
        prev = match[0]
        after = match[2]
        p1 = match[1].replace(',', '|')
        new_reg = prev + '(' + p1 + ')' + after

    new_reg = new_reg.replace('?', '[^/\000]')

    multi_glob = '__KJHDKVZH_AAPROF_INTERNAL_GLOB_SVCUZDGZID__'
    new_reg = new_reg.replace('**', multi_glob)
    #print(new_reg)

    # Match atleast one character if * or ** after /
    # ?< is the negative lookback operator
    new_reg = new_reg.replace('*', '(((?<=/)[^/\000]+)|((?<!/)[^/\000]*))')
    new_reg = new_reg.replace(multi_glob, '(((?<=/)[^\000]+)|((?<!/)[^\000]*))')
    if regexp[0] != '^':
        new_reg = '^' + new_reg
    if regexp[-1] != '$':
        new_reg = new_reg + '$'
    return new_reg

def user_perm(prof_dir):
    if not os.access(prof_dir, os.W_OK):
        sys.stdout.write("Cannot write to profile directory.\n" +
                         "Please run as a user with appropriate permissions.\n")
        return False
    return True

class DebugLogger(object):
    def __init__(self, module_name=__name__):
        self.debugging = False
        self.logfile = '/var/log/apparmor/logprof.log'
        self.debug_level = logging.DEBUG
        if os.getenv('LOGPROF_DEBUG', False):
            self.debugging = os.getenv('LOGPROF_DEBUG')
            try:
                self.debugging = int(self.debugging)
            except Exception:
                self.debugging = False
            if self.debugging not in range(0, 4):
                sys.stdout.write('Environment Variable: LOGPROF_DEBUG contains invalid value: %s'
                                 % os.getenv('LOGPROF_DEBUG'))
            if self.debugging == 0:  # debugging disabled, don't need to setup logging
                return
            if self.debugging == 1:
                self.debug_level = logging.ERROR
            elif self.debugging == 2:
                self.debug_level = logging.INFO
            elif self.debugging == 3:
                self.debug_level = logging.DEBUG

            try:
                logging.basicConfig(filename=self.logfile, level=self.debug_level,
                                    format='%(asctime)s - %(name)s - %(message)s\n')
            except OSError:
                # Unable to open the default logfile, so create a temporary logfile and tell use about it
                import tempfile
                templog = tempfile.NamedTemporaryFile('w', prefix='apparmor', suffix='.log', delete=False)
                sys.stdout.write("\nCould not open: %s\nLogging to: %s\n" % (self.logfile, templog.name))

                logging.basicConfig(filename=templog.name, level=self.debug_level,
                                    format='%(asctime)s - %(name)s - %(message)s\n')

            self.logger = logging.getLogger(module_name)

    def error(self, message):
        if self.debugging:
            self.logger.error(message)

    def info(self, message):
        if self.debugging:
            self.logger.info(message)

    def debug(self, message):
        if self.debugging:
            self.logger.debug(message)

    def shutdown(self):
        logging.shutdown()
        #logging.shutdown([self.logger])
