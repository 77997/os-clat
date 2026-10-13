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
 * Plugin settings are read from the global $config array and not through
 * the model: a pending legacy edit is already visible there, and no model
 * object can throw inside a hook.  The array holds no model defaults, so
 * the defaults of Clat.xml that these hooks need are repeated here.
 */
function clat_setting($name)
{
    global $config;

    $defaults = [
        'enabled' => '1',
        'mss_clamp' => '1',
        'firewall_rule' => '1',
        'ipv4_mtu' => '1500',
    ];

    $value = $config['OPNsense']['clat']['general'][$name] ?? null;

    /* not empty(): '0' is a stored value (mode Disabled, a cleared checkbox) */
    if ($value === null || $value === '' || is_array($value)) {
        return $defaults[$name] ?? '';
    }

    return (string)$value;
}

function clat_enabled()
{
    return clat_setting('enabled') == '1';
}

/*
 * The configured uplink is an interface key derived from config.xml only:
 * the hooks below must work while IPv6 is down.
 */
function clat_configured_uplink()
{
    $interfaces = config_read_array('interfaces', false);
    $uplink = clat_setting('uplink');

    if ($uplink !== '') {
        return isset($interfaces[$uplink]['enable']) ? $uplink : null;
    }

    $first = null;

    foreach ($interfaces as $key => $intf) {
        if (
            $key === 'clat' || !isset($intf['enable']) || !empty($intf['virtual']) ||
            !in_array($intf['ipaddrv6'] ?? '', ['dhcp6', 'slaac'], true)
        ) {
            continue;
        }
        if ($key === 'wan') {
            return 'wan';
        }
        if ($first === null) {
            $first = (string)$key;
        }
    }

    return $first;
}

/* the uplink MTU as interface_ppps_configure() and interface_configure() derive it */
function clat_configured_uplink_mtu($key)
{
    if ($key === null) {
        return 1500;
    }

    $ifcfg = config_read_array('interfaces', $key, false);

    foreach (config_read_array('ppps', 'ppp', false) as $ppp) {
        if (!empty($ifcfg['if']) && $ifcfg['if'] == ($ppp['if'] ?? '')) {
            $mtus = !empty($ppp['mtu']) ? explode(',', $ppp['mtu']) : [];
            if (empty($mtus[0])) {
                /* subtract the PPPoE header when deriving from the interface setting */
                $mtus[0] = !empty($ifcfg['mtu']) ? intval($ifcfg['mtu']) - 8 : 1492;
            }
            return (int)$mtus[0];
        }
    }

    return !empty($ifcfg['mtu']) ? (int)$ifcfg['mtu'] : 1500;
}

/* value of the interface "mss" key: core clamps to it minus 60 for IPv6 */
function clat_mss()
{
    if (clat_setting('mss_clamp') != '1') {
        return '';
    }

    $mtu = clat_configured_uplink_mtu(clat_configured_uplink());

    /* the override can only lower the value */
    $override = (int)clat_setting('ipv6_mtu');
    if ($override > 0) {
        $mtu = min($mtu, $override);
    }

    return min($mtu, (int)clat_setting('ipv4_mtu') + 20) - (int)clat_setting('mss_offset');
}

function clat_services()
{
    $services = [];

    if (clat_enabled()) {
        $services[] = [
            'description' => gettext('CLAT'),
            'configd' => [
                'restart' => ['clat restart'],
                'start' => ['clat start'],
                'stop' => ['clat stop'],
            ],
            'name' => 'clat',
            'pidfile' => '/var/run/clat.pid',
        ];
    }

    return $services;
}

function clat_syslog()
{
    return ['clat' => ['facility' => ['clat']]];
}

function clat_devices()
{
    $devices = [];

    if (clat_enabled()) {
        $devices[] = [
            'function' => 'clat_configure_device',
            'configurable' => false,
            'names' => [
                'tun464' => [
                    'descr' => 'tun464 (CLAT)',
                    'ifdescr' => 'CLAT',
                    'name' => 'tun464',
                ],
            ],
            'pattern' => '^tun464$',
            'spoofmac' => false,
            'volatile' => true,
            'type' => 'clat',
            'typedescr' => gettext('CLAT'),
        ];
    }

    return $devices;
}

function clat_configure_device($device)
{
    if ($device != 'tun464') {
        return;
    }

    if (!does_interface_exist($device)) {
        legacy_interface_create($device);
    }

    /*
     * Core removes the router file whenever the interface record is
     * applied.  The daemon keeps this marker while the CLAT gateway is
     * up, so put the file back in that case.
     */
    if (is_readable('/var/run/clat/gateway')) {
        $gateway = trim((string)@file_get_contents('/var/run/clat/gateway'));
        if (is_ipaddrv4($gateway) && isvalidpid('/var/run/clat.pid')) {
            mwexecf('/usr/local/sbin/ifctl -i %s -4rd -a %s', [$device, $gateway]);
        }
    }
}

/* a pure function of config.xml: reads no device and no daemon state */
function clat_interfaces()
{
    $interfaces = [];

    if (clat_enabled()) {
        $interfaces['clat'] = [
            'enable' => true,
            'if' => 'tun464',
            'descr' => 'CLAT',
            'type' => 'none',
            'ipaddr' => '',
            'ipaddrv6' => '',
            'mss' => clat_mss(),
        ];
    }

    return $interfaces;
}

function clat_firewall($fw)
{
    global $config;

    if (!clat_enabled() || clat_setting('firewall_rule') != '1') {
        return;
    }

    /* tayga writes the translated packet back into the tun: pf sees new inbound IPv6 there */
    $fw->registerFilterRule(
        1,
        [
            'type' => 'pass',
            'direction' => 'in',
            'quick' => true,
            'interface' => 'clat',
            'ipprotocol' => 'inet6',
            'statetype' => 'keep',
            'disablereplyto' => 1,
            'log' => !isset($config['syslog']['nologdefaultpass']),
            'descr' => 'CLAT: translated IPv6 from tayga',
            '#ref' => 'ui/clat',
        ]
    );
}

function clat_configure()
{
    if (!clat_enabled()) {
        return [];
    }

    return [
        'newwanip' => ['clat_event:3'],
    ];
}

function clat_event($verbose = false, $interfaces = null, $family = null)
{
    if (!plugins_argument_map($interfaces)) {
        return;
    }

    /* the daemon raises exactly this event when it activates: reacting to it would loop */
    if (is_array($interfaces) && array_values($interfaces) === ['clat']) {
        return;
    }

    $family = $family === 'inet6' ? 'inet6' : 'inet';
    $hit = $interfaces === null || in_array(clat_configured_uplink(), $interfaces, true);

    configdp_run('clat event', [$family, $hit ? '1' : '0'], true);
}
