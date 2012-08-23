# ------------------------------------------------------------------
#
#    Copyright (C) 2011-2012 Canonical Ltd.
#
#    This program is free software; you can redistribute it and/or
#    modify it under the terms of version 2 of the GNU General Public
#    License published by the Free Software Foundation.
#
# ------------------------------------------------------------------

from apparmor.common import AppArmorException, debug, error, cmd
import apparmor.easyprof
import optparse
import os
import pwd
import re
import sys
import tempfile
import time

def check_requirements(binary):
    '''Verify necessary software is installed'''
    exes = ['Xephyr',
            'matchbox-window-manager',
            'xset',        # for detecting free X display
            'aa-easyprof', # for templates
            'sudo',        # eventually get rid of this
            binary]
    for e in exes:
        debug("Searching for '%s'" % e)
        rc, report = cmd(['which', e])
        if rc != 0:
            error("Could not find '%s'" % e, do_exit=False)
            return False
    return True

def parse_args(args=None, parser=None):
    '''Parse arguments'''
    if parser == None:
        parser = optparse.OptionParser()

    parser.add_option('-X', '--with-x',
                      dest='withx',
                      default=False,
                      help='Run in isolated X server',
                      action='store_true')
    parser.add_option('-d', '--debug',
                      dest='debug',
                      default=False,
                      help='Show debug messages',
                      action='store_true')
    parser.add_option('-r', '--with-resolution',
                      dest='resolution',
                      default='640x480',
                      help='Resolution for X application')

    (my_opt, my_args) = parser.parse_args()
    if my_opt.debug == True:
        apparmor.common.DEBUGGING = True
    if my_opt.template == "default":
        if my_opt.withx:
            my_opt.template = "sandbox-x"
        else:
            my_opt.template = "sandbox"
        

    return (my_opt, my_args)

def gen_policy_name(binary):
    '''Generate a temporary policy based on the binary name'''
    return "sandbox-%s%s" % (pwd.getpwuid(os.getuid())[0],
                              re.sub(r'/', '_', binary))

def aa_exec(command, opt):
    '''Execute binary under specified policy'''
    opt.ensure_value("template_var", None)
    opt.ensure_value("name", None)
    opt.ensure_value("comment", None)
    opt.ensure_value("author", None)
    opt.ensure_value("copyright", None)

    binary = command[0]
    policy_name = apparmor.sandbox.gen_policy_name(binary)
    easyp = apparmor.easyprof.AppArmorEasyProfile(binary, opt)
    params = apparmor.easyprof.gen_policy_params(policy_name, opt)
    policy = easyp.gen_policy(**params)
    debug("\n%s" % policy)

    # TODO: get rid of sudo
    tmp = tempfile.NamedTemporaryFile(prefix = '%s-' % policy_name)
    if sys.version_info[0] >= 3:
        tmp.write(bytes(policy, 'utf-8'))
    else:
        tmp.write(policy)

    tmp.flush()
    debug("using '%s' template" % opt.template)
    rc, report = cmd(['sudo', 'apparmor_parser', '-r', tmp.name])
    if rc != 0:
        raise AppArmorException("Could not load policy")

    args = ['aa-exec', '-p', policy_name] + command
    rc, report = cmd(args)
    return rc, report

def find_free_x_display():
    '''Find a free X display'''
    x_display = ""
    current = os.environ["DISPLAY"]
    for i in range(1,257): # TODO: this puts an artificial limit of 256
                           #       sandboxed applications
        tmp = ":%d" % i
        os.environ["DISPLAY"] = tmp
        rc, report = cmd(['xset', '-q'])
        if rc != 0:
            x_display = tmp
            break
        
    os.environ["DISPLAY"] = current
    if x_display == "":
        raise AppArmorException("Could not find available X display")

    return x_display

def run_sandbox(command, opt):
    '''Run application'''
    # aa-exec
    #opt.template = "sandbox-x"
    rc, report = aa_exec(command, opt)
    return rc, report

def run_xsandbox(command, opt):
    '''Run X application in a sandbox'''
    # Find a display to run on
    x_display = find_free_x_display()

    debug ("DISPLAY=%s" % os.environ["DISPLAY"])

    # first, start X
    listener_x = os.fork()
    if listener_x == 0:
        # TODO: break into config file? Which are needed?
        x_exts = ['-extension', 'GLX',
                  '-extension', 'MIT-SHM',
                  '-extension', 'RENDER',
                  '-extension', 'SECURITY',
                  '-extension', 'DAMAGE'
                 ]
        # verify_these
        x_extra_args = ['-host-cursor', # less secure?
                        '-fakexa',      # for games? seems not needed
                        '-nodri',       # more secure?
                       ]

        x_args = ['-nolisten', 'tcp',
                  '-screen', opt.resolution,
                  '-br',        # black background
                  '-reset',     # reset after last client exists
                  '-terminate', # terminate at server reset
                  '-title', command[0],
                  ] + x_exts + x_extra_args

        args = ['/usr/bin/Xephyr'] + x_args + [x_display]
        debug(" ".join(args))
        sys.stderr.flush()
        os.execv(args[0], args)
        sys.exit(0)

    # save environment
    old_display = os.environ["DISPLAY"]
    old_cwd = os.getcwd()

    # update environment
    os.environ["DISPLAY"] = x_display
    debug("DISPLAY is now '%s'" % os.environ["DISPLAY"])

    time.sleep(0.2) # FIXME: detect if running

    # Next, start the window manager
    sys.stdout.flush()
    os.chdir(os.environ["HOME"])
    listener_wm = os.fork()
    if listener_wm == 0:
        args = ['/usr/bin/matchbox-window-manager', '-use_titlebar', 'no']
        debug(" ".join(args))
        sys.stderr.flush()
        os.execv(args[0], args)
        sys.exit(0)

    time.sleep(0.2) # FIXME: detect if running

    # aa-exec
    rc, report = aa_exec(command, opt)

    # reset environment
    os.environ["DISPLAY"] = old_display
    debug("DISPLAY is now '%s'" % os.environ["DISPLAY"])

    os.chdir(old_cwd)

    # kill server now. It should've terminated, but be sure
    cmd(['kill', '-15', "%d" % listener_wm])
    os.kill(listener_wm, 15)
    os.waitpid(listener_wm, 0)
    cmd(['kill', '-15', "%d" % listener_x])
    os.kill(listener_x, 15)
    os.waitpid(listener_x, 0)

    return rc, report
