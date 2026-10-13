#!/usr/local/bin/php
<?php

/*
 * Copyright (C) 2026 os-clat contributors
 * All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions are met:
 *
 * 1. Redistributions of source code must retain the above copyright notice,
 *    this list of conditions and the following disclaimer.
 *
 * 2. Redistributions in binary form must reproduce the above copyright
 *    notice, this list of conditions and the following disclaimer in the
 *    documentation and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED ``AS IS'' AND ANY EXPRESS OR IMPLIED WARRANTIES,
 * INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY
 * AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE
 * AUTHOR BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY,
 * OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
 * SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
 * INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
 * CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
 * ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
 * POSSIBILITY OF SUCH DAMAGE.
 */

/*
 * Facts for the CLAT daemon that only core's PHP code can give, as one line
 * of JSON.  Argument "config", "gateways" or none (both).  Never writes
 * configuration.
 */

require_once 'config.inc';
require_once 'util.inc';
require_once 'interfaces.inc';
require_once 'plugins.inc.d/clat.inc';

/* facts from config.xml only */
function clat_facts_config()
{
    global $config;

    $interfaces = config_read_array('interfaces', false);

    $uplink = null;
    $key = clat_configured_uplink();
    if ($key !== null) {
        $ifcfg = config_read_array('interfaces', $key, false);
        $is_ppp = false;
        foreach (config_read_array('ppps', 'ppp', false) as $ppp) {
            if (!empty($ifcfg['if']) && $ifcfg['if'] == ($ppp['if'] ?? '')) {
                $is_ppp = true;
                break;
            }
        }
        $uplink = [
            'key' => $key,
            'if' => get_real_interface($key, 'inet6'),
            'ppp' => $is_ppp,
            'ipv4_ppp' => in_array($ifcfg['ipaddr'] ?? '', ['ppp', 'pppoe', 'pptp', 'l2tp'], true),
            'mtu' => clat_configured_uplink_mtu($key),
            'mss' => is_numeric($ifcfg['mss'] ?? '') ? (int)$ifcfg['mss'] : null,
        ];
    }

    $mss = clat_mss();

    /* normalisation switch: the model node of newer versions, else the legacy one */
    $filter = config_read_array('OPNsense', 'Firewall', 'Filter', 'settings', 'filter', false);
    if (isset($filter['scrub_enabled'])) {
        $scrub = !empty($filter['scrub_enabled']);
    } else {
        $scrub = empty($config['system']['scrub_interface_disable']);
    }

    /* would plugins_interfaces() change the record? (same test as there) */
    $record_ok = true;
    foreach (clat_interfaces() as $ifkey => $wanted) {
        $have = config_read_array('interfaces', $ifkey, false);
        if (!isset($have['internal_dynamic'])) {
            $record_ok = false;
        }
        foreach ($wanted as $prop => $value) {
            if ((empty($have[$prop]) && !empty($value)) || ($have[$prop] ?? '') != $value) {
                $record_ok = false;
            }
        }
    }

    $devices = [];
    $static_v6 = [];
    foreach ($interfaces as $ifkey => $ifcfg) {
        if (!isset($ifcfg['enable'])) {
            continue;
        }
        if (is_ipaddrv6($ifcfg['ipaddrv6'] ?? '') && is_numeric($ifcfg['subnetv6'] ?? '')) {
            $static_v6[] = $ifcfg['ipaddrv6'] . '/' . $ifcfg['subnetv6'];
        }
        if (empty($ifcfg['if']) || !empty($ifcfg['virtual'])) {
            continue;
        }
        /* /64 indexes of a delegation on this interface that config.xml hands out */
        $claims = [];
        if (is_numeric($ifcfg['dhcp6-prefix-id'] ?? '')) {
            $claims[(int)$ifcfg['dhcp6-prefix-id']] = true;
        }
        foreach ($interfaces as $lancfg) {
            if (
                !isset($lancfg['enable']) || !empty($lancfg['virtual']) ||
                !in_array($lancfg['ipaddrv6'] ?? '', ['track6', 'idassoc6'], true) ||
                ($lancfg['track6-interface'] ?? '') != $ifkey ||
                !is_numeric($lancfg['track6-prefix-id'] ?? '')
            ) {
                continue;
            }
            $first = (int)$lancfg['track6-prefix-id'];
            $count = max(1, (int)($lancfg['track6_prefix_range'] ?? 0));
            for ($id = $first; $id < $first + $count; $id++) {
                $claims[$id] = true;
            }
        }
        ksort($claims);
        $devices[$ifcfg['if']] = ['key' => (string)$ifkey, 'claims' => array_keys($claims)];
    }

    return [
        'uplink' => $uplink,
        'mss' => $mss === '' ? null : (int)$mss,
        'nat_mode' => (string)($config['nat']['outbound']['mode'] ?? ''),
        'scrub' => $scrub,
        'record_ok' => $record_ok,
        'interfaces' => (object)$devices,
        'static_v6' => $static_v6,
    ];
}

/* facts from core's gateway list and the addresses on the devices */
function clat_facts_gateways()
{
    global $config;

    $ifdetails = legacy_interfaces_details();
    $gateways = new \OPNsense\Routing\Gateways();
    $uplink = clat_configured_uplink();

    /* same skip list as system_routing_configure() */
    $down = [];
    if (isset($config['system']['gw_switch_default'])) {
        foreach (return_gateways_status() as $gwname => $gwstatus) {
            if (strpos($gwstatus['status'], 'down') !== false) {
                $down[] = $gwname;
            }
        }
    }

    /* what still refers to a gateway by name */
    $dns_refs = [];
    foreach (config_read_array('system', false) as $prop => $value) {
        if (preg_match('/^dns[0-9]+gw$/', $prop)) {
            $dns_refs[] = $value;
        }
    }
    $rules = array_merge(
        config_read_array('filter', 'rule', false),
        config_read_array('OPNsense', 'Firewall', 'Filter', 'rules', 'rule', false)
    );
    $rule_refs = [];
    foreach ($rules as $rule) {
        if (!empty($rule['gateway'])) {
            $rule_refs[] = $rule['gateway'];
        }
    }

    $list = [];
    $own = [];
    $leftover = [];
    foreach ($gateways->getGateways() as $gw) {
        if (($gw['ipprotocol'] ?? '') != 'inet' || !empty($gw['is_loopback'])) {
            continue;
        }
        $name = (string)($gw['name'] ?? '');
        $interface = (string)($gw['interface'] ?? '');
        $device = (string)($gw['if'] ?? '');
        $list[] = [
            'name' => $name,
            'interface' => $interface,
            'if' => $device,
            'gateway' => (string)($gw['gateway'] ?? ''),
            'priority' => (int)($gw['priority'] ?? 255),
            'upstream' => !empty($gw['defaultgw']),
            'disabled' => !empty($gw['disabled']),
            'defunct' => !empty($gw['defunct']),
            'dynamic' => !empty($gw['dynamic']),
            'selected' => ($config['interfaces'][$interface]['gateway'] ?? null) === $name,
            'tunnel' => (bool)preg_match('/^(gre|gif|ovpn|wg|ipsec)/', $device),
            'if_has_ipv4' => !empty($ifdetails[$device]['ipv4'][0]),
        ];
        if ($device == 'tun464') {
            $own[] = $name;
        }
        if (!empty($gw['defunct']) && $uplink !== null && $interface === $uplink) {
            $refs = [];
            if (!empty($gw['monitor'])) {
                $refs[] = 'monitor';
            }
            if (in_array($name, $dns_refs, true)) {
                $refs[] = 'dns';
            }
            if (in_array($name, $rule_refs, true)) {
                $refs[] = 'rule';
            }
            if (!empty($refs)) {
                $leftover[] = ['name' => $name, 'refs' => $refs];
            }
        }
    }

    $default = $gateways->getDefaultGW($down, 'inet');
    if ($default !== null) {
        $default = [
            'name' => (string)($default['name'] ?? ''),
            'if' => (string)($default['if'] ?? ''),
            'if_has_ipv4' => !empty($ifdetails[$default['if'] ?? '']['ipv4'][0]),
        ];
    }

    /* another usable IPv4 gateway: the default core would pick without the CLAT */
    $fallback = $gateways->getDefaultGW(array_merge($down, $own), 'inet');
    if (!empty($fallback['gateway']) && !empty($ifdetails[$fallback['if'] ?? '']['ipv4'][0])) {
        $fallback = (string)$fallback['name'];
    } else {
        $fallback = null;
    }

    return [
        'default' => $default,
        'fallback' => $fallback,
        'list' => $list,
        'leftover' => $leftover,
    ];
}

$mode = $argv[1] ?? '';
$result = [];

if ($mode !== 'gateways') {
    $result['config'] = clat_facts_config();
}
if ($mode !== 'config') {
    $result['gateways'] = clat_facts_gateways();
}

echo json_encode($result) . PHP_EOL;
