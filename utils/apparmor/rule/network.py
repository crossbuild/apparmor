#!/usr/bin/env python
# ----------------------------------------------------------------------
#    Copyright (C) 2013 Kshitij Gupta <kgupta8592@gmail.com>
#    Copyright (C) 2015 Christian Boltz <apparmor@cboltz.de>
#
#    This program is free software; you can redistribute it and/or
#    modify it under the terms of version 2 of the GNU General Public
#    License as published by the Free Software Foundation.
#
#    This program is distributed in the hope that it will be useful,
#    but WITHOUT ANY WARRANTY; without even the implied warranty of
#    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#    GNU General Public License for more details.
#
# ----------------------------------------------------------------------

import re

from apparmor.regex import RE_PROFILE_NETWORK
from apparmor.common import AppArmorBug, AppArmorException
from apparmor.rule import BaseRule, BaseRuleset, parse_modifiers

# setup module translations
from apparmor.translations import init_translation
_ = init_translation()


network_domain_keywords   = [ 'unix', 'inet', 'ax25', 'ipx', 'appletalk', 'netrom', 'bridge', 'atmpvc', 'x25', 'inet6',
                              'rose', 'netbeui', 'security', 'key', 'netlink', 'packet', 'ash', 'econet', 'atmsvc', 'rds', 'sna',
                              'irda', 'pppox', 'wanpipe', 'llc', 'can', 'tipc', 'bluetooth', 'iucv', 'rxrpc', 'isdn', 'phonet',
                              'ieee802154', 'caif', 'alg', 'nfc', 'vsock' ]

network_type_keywords     = ['stream', 'dgram', 'seqpacket', 'rdm', 'raw', 'packet']
network_protocol_keywords = ['tcp', 'udp', 'icmp']


RE_NETWORK_DOMAIN   = '(' + '|'.join(network_domain_keywords) + ')'
RE_NETWORK_TYPE     = '(' + '|'.join(network_type_keywords) + ')'
RE_NETWORK_PROTOCOL = '(' + '|'.join(network_protocol_keywords) + ')'

RE_NETWORK_DETAILS  = re.compile(
    '^\s*(' +
        '(?P<domain>' + RE_NETWORK_DOMAIN + ')' + # domain and ...
            '(\s+(?P<type_or_protocol>' + RE_NETWORK_TYPE + '|' + RE_NETWORK_PROTOCOL + '))?' + # ... optional type or protocol
        '|' + # or
        '(?P<protocol>' + RE_NETWORK_PROTOCOL + ')' + # protocol only
    ')\s*$')


class NetworkRule(BaseRule):
    '''Class to handle and store a single network rule'''

    # Nothing external should reference this class, all external users
    # should reference the class field NetworkRule.ALL
    class __NetworkAll(object):
        pass

    ALL = __NetworkAll

    def __init__(self, domain, type_or_protocol, audit=False, deny=False, allow_keyword=False,
                 comment='', log_event=None):

        '''
           NETWORK RULE = 'network' [ [ DOMAIN [ TYPE | PROTOCOL ] ] | [ PROTOCOL ] ] ','
        '''

        super(NetworkRule, self).__init__(audit=audit, deny=deny,
                                             allow_keyword=allow_keyword,
                                             comment=comment,
                                             log_event=log_event)

        self.domain = None
        self.all_domains = False
        if domain == NetworkRule.ALL:
            self.all_domains = True
        elif type(domain) == str:
            if domain in network_domain_keywords:
                self.domain = domain
            else:
                raise AppArmorBug('Passed unknown domain to NetworkRule: %s' % domain)
        else:
            raise AppArmorBug('Passed unknown object to NetworkRule: %s' % str(domain))

        self.type_or_protocol = None
        self.all_type_or_protocols = False
        if type_or_protocol == NetworkRule.ALL:
            self.all_type_or_protocols = True
        elif type(type_or_protocol) == str:
            if type_or_protocol in network_protocol_keywords:
                self.type_or_protocol = type_or_protocol
            elif type_or_protocol in network_type_keywords:
                if self.all_domains:
                    raise AppArmorException('Passing type %s to NetworkRule without specifying a domain keyword is not allowed' % type_or_protocol)
                self.type_or_protocol = type_or_protocol
            else:
                raise AppArmorBug('Passed unknown type_or_protocol to NetworkRule: %s' % type_or_protocol)
        else:
            raise AppArmorBug('Passed unknown object to NetworkRule: %s' % str(type_or_protocol))

    @classmethod
    def _match(cls, raw_rule):
        return RE_PROFILE_NETWORK.search(raw_rule)

    @classmethod
    def _parse(cls, raw_rule):
        '''parse raw_rule and return NetworkRule'''

        matches = cls._match(raw_rule)
        if not matches:
            raise AppArmorException(_("Invalid network rule '%s'") % raw_rule)

        audit, deny, allow_keyword, comment = parse_modifiers(matches)

        rule_details = ''
        if matches.group('details'):
            rule_details = matches.group('details').strip()

        if rule_details:
            details = RE_NETWORK_DETAILS.search(rule_details)
            if not details:
                raise AppArmorException(_("Invalid or unknown keywords in 'network %s" % rule_details))

            if details.group('domain'):
                domain = details.group('domain')
            else:
                domain = NetworkRule.ALL

            if details.group('type_or_protocol'):
                type_or_protocol = details.group('type_or_protocol')
            elif details.group('protocol'):
                type_or_protocol = details.group('protocol')
            else:
                type_or_protocol = NetworkRule.ALL
        else:
            domain = NetworkRule.ALL
            type_or_protocol = NetworkRule.ALL

        return NetworkRule(domain, type_or_protocol,
                           audit=audit, deny=deny, allow_keyword=allow_keyword, comment=comment)

    def get_clean(self, depth=0):
        '''return rule (in clean/default formatting)'''

        space = '  ' * depth

        if self.all_domains:
            domain = ''
        elif self.domain:
            domain = ' %s' % self.domain
        else:
            raise AppArmorBug('Empty domain in network rule')

        if self.all_type_or_protocols:
            type_or_protocol = ''
        elif self.type_or_protocol:
            type_or_protocol = ' %s' % self.type_or_protocol
        else:
            raise AppArmorBug('Empty type or protocol in network rule')

        return('%s%snetwork%s%s,%s' % (space, self.modifiers_str(), domain, type_or_protocol, self.comment))

    def is_covered_localvars(self, other_rule):
        '''check if other_rule is covered by this rule object'''

        if not other_rule.domain and not other_rule.all_domains:
            raise AppArmorBug('No domain specified in other network rule')

        if not other_rule.type_or_protocol and not other_rule.all_type_or_protocols:
            raise AppArmorBug('No type or protocol specified in other network rule')

        if not self.all_domains:
            if other_rule.all_domains:
                return False
            if other_rule.domain != self.domain:
                return False

        if not self.all_type_or_protocols:
            if other_rule.all_type_or_protocols:
                return False
            if other_rule.type_or_protocol != self.type_or_protocol:
                return False

        # still here? -> then it is covered
        return True

    def is_equal_localvars(self, rule_obj):
        '''compare if rule-specific variables are equal'''

        if not type(rule_obj) == NetworkRule:
            raise AppArmorBug('Passed non-network rule: %s' % str(rule_obj))

        if (self.domain != rule_obj.domain
                or self.all_domains != rule_obj.all_domains):
            return False

        if (self.type_or_protocol != rule_obj.type_or_protocol
                or self.all_type_or_protocols != rule_obj.all_type_or_protocols):
            return False

        return True


class NetworkRuleset(BaseRuleset):
    '''Class to handle and store a collection of network rules'''

    def get_glob(self, path_or_rule):
        '''Return the next possible glob. For network rules, that's "network DOMAIN," or "network," (all network)'''
        # XXX return 'network DOMAIN,' if 'network DOMAIN TYPE_OR_PROTOCOL' was given
        return 'network,'
