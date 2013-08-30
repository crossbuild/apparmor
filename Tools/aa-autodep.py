#!/usr/bin/python

import argparse

import apparmor.tools

parser = argparse.ArgumentParser(description='')
parser.add_argument('--force', type=str, help='path to profiles')
parser.add_argument('-d', type=str, help='path to profiles')
parser.add_argument('program', type=str, nargs='+', help='name of program')
args = parser.parse_args()

autodep = apparmor.tools.aa_tools('autodep', args)

autodep.act()