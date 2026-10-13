/*
 * steps.mjs - the pictures capture.mjs takes of the OPNsense GUI, one entry per picture. Data only.
 *
 * The steps follow the OPNsense section of the ISP's router-setup page (https://gettuckamore.ca/router/setup):
 * the base steps 1 to 9 and the MTU check, the optional "Devices translate" steps (dt), and "Router translates"
 * with the os-clat plugin (rt).
 *
 * An entry:
 *   id       how the step is named on the command line
 *   set      'now' (default): taken on the lab as it is. 'vlan': shows PPPoE on VLAN 40, so it needs the trunk
 *            (lab README section 13). 'fresh': the plugin must not be installed yet (lab README section 15)
 *   file     the PNG, in the output folder
 *   title    one line for a person
 *   url      the page, as the menu has it
 *   view     { width, height } of the window when the default below does not fit the page
 *   actions  done in order after the page is quiet, each { verb: value }:
 *              click: SEL         click the first visible match, then wait until the page is quiet again
 *              wait: SEL          wait until a visible element matches;   gone: SEL   until none does
 *              until: JS          wait until the expression is true in the page
 *              set: SEL, to: V    put a value into a field of the open page: text, the text or value of a choice
 *                                 (a list for several, [] for none), true or false for a tick. Nothing is saved
 *              hide: SEL          take a part of the page out of the picture (a box the step is not about)
 *              pause: MS          for an animation
 *              js: JS             an expression in the page; what it returns is printed
 *   clip     selectors; the picture is the rectangle around everything visible they match (pad: pixels around it)
 *            A dialog is taken without the page behind it
 *   expect   what a reader must be able to see in the picture, checked before it is saved:
 *              'text'                         readable inside the rectangle
 *              { field: SEL, is: V }          the field is inside it and shows V (true or false for a tick,
 *                                             the text of the choice for a list)
 *              { absent: 'text' }             must not be readable
 *   after    actions once the picture is saved, to close what the step opened (a dialog: Cancel)
 *
 * SEL is CSS, "CSS >> text" (the matches whose text contains the text), or "CSS >> text >> CSS" (inside those).
 * The window is 1024 wide, which makes the content column 768 pixels: about the width of the customer page's text
 * column, so a picture is shown there nearly pixel for pixel. Grids with many columns get 1280.
 */

export const view = { width: 1024, height: 900 };

/* Shown in place of lab values: { secret: KEY of secrets.env } or { text: literal }, and what a reader sees instead. */
export const neutral = [
    { secret: 'PPPOE_USER', show: 'YOUR_USERNAME' },
];

const wide = { width: 1280, height: 900 };
const head = '.page-content-head';
const tabs = '.page-content-main ul.nav-tabs';
const dialog = '.modal.in .modal-content';
const opened = [{ wait: dialog }, { pause: 500 }];
const cancel = [{ click: '.modal.in .modal-footer button >> Cancel' }];
const close = [{ click: '.modal.in .modal-footer button >> Close' }];
/* rows of the interface lists that a subscriber at the base steps does not have: the lab's management port, the plugin's interface */
const labRows = [{ hide: '.tabulator-row >> MGMT' }, { hide: '.tabulator-row >> tun464' }];
const box = (text) => `#iform .content-box >> ${text}`;                 // a box of Interfaces: [NAME], by its heading
const id = (name) => `[id="${name}"]`;                                  // MVC field ids contain dots

/* Interfaces: [NAME] */
const iface = (name) => `/interfaces.php?if=${name}`;

/* Services: Dnsmasq DNS & DHCP, General: the DHCP part only */
const dnsmasqGeneral = [
    { wait: '#general.active ' + id('dnsmasq.dhcp.enable_ra') },
    { hide: `#frm_settings table:has(tr[id^="row_dnsmasq"]):not(:has(${id('dnsmasq.dhcp.enable_ra')}))` },
];
/* Services: Dnsmasq DNS & DHCP, DHCP ranges: the LAN entry with the constructor, opened */
const dnsmasqRange = [
    { wait: '#dhcpranges.active .tabulator-group' },
    { click: '#dhcpranges .tabulator-group >> LAN >> .tabulator-arrow' },
    { wait: '#dhcpranges .tabulator-row >> ::1000' },
    { click: '#dhcpranges .tabulator-row >> ::1000 >> .command-edit' },
    ...opened,
];
/* Interfaces: Overview, the Details of one interface */
const details = (row) => [
    { wait: '#grid-overview .tabulator-row >> ' + row },
    { click: `#grid-overview .tabulator-row >> ${row} >> .command-interface_info` },
    ...opened,
];
/* System: Firmware, Plugins: the community plugins shown, the list narrowed to os-clat */
const plugins = [
    { wait: '#pluginlist tr.plugin_entry' },
    { set: '#plugin_search', to: 'os-clat' },
];

export const steps = [
    /* ---- the base steps ---- */
    {
        id: '01-wan-none', file: 'opnsense-01-wan-none.png', title: '1. Clear the WAN port',
        url: iface('wan'), view: { width: 1024, height: 1400 },         // room below the lists, or they open upwards
        actions: [{ set: '#type', to: 'None' }, { set: '#type6', to: 'None' }, { hide: box('Basic configuration') }],
        clip: [head, 'tr:has(#type6)'],
        expect: ['Interfaces: [WAN]', { field: '#type', is: 'None' }, { field: '#type6', is: 'None' }],
    },
    {
        id: '02-vlan', set: 'vlan', file: 'opnsense-02-vlan.png', title: '2. Add VLAN 40',
        url: '/ui/interfaces/vlan',
        /* the picture shows what a reader has at step 2: no Description (the page asks for none; the device of profile
           P0 has "ISP"), and the port still under the name WAN (it becomes UPLINK in step 4; lab README section 13
           has the row the box showed at step 2). Both are put into the open page; nothing is saved */
        actions: [{ wait: '.tabulator-row >> vlan0.40' }, { click: '.tabulator-row >> vlan0.40 >> .command-edit' }, ...opened,
            { set: id('vlan.descr'), to: '' },
            { js: `(() => { const list = document.getElementById('vlan.if'); const choice = list.options[list.selectedIndex];
                choice.textContent = choice.textContent.replace(/\\[[^\\]]*\\]\\s*$/, '[WAN]');
                window.jQuery(list).selectpicker('refresh'); return 'Parent shown as ' + choice.textContent.trim(); })()` }],
        clip: [dialog],
        expect: [{ field: id('vlan.vlanif'), is: 'vlan0.40' }, { field: id('vlan.tag'), is: '40' }, 'hn1', '[WAN]', { absent: '[UPLINK]' },
            { field: id('vlan.descr'), is: '' }],
        after: cancel,
    },
    {
        id: '03-pppoe', set: 'vlan', file: 'opnsense-03-pppoe.png', title: '3. Add PPPoE',
        url: '/interfaces_ppps_edit.php?id=0',
        clip: [head, '.content-box:has(#username)', '.content-box:has(input[name=Submit])'],
        expect: ['Interfaces: Devices: Point-to-Point', { field: '#type', is: 'PPPoE' }, 'vlan0.40',
            { field: '#username', is: 'YOUR_USERNAME' }, '(password: masked)', { field: '#provider', is: '' }, { field: '#hostuniq', is: '' }],
    },
    {
        id: '04-assignments', set: 'vlan', file: 'opnsense-04-assignments.png', title: '4. Make PPPoE your WAN: the list',
        url: '/ui/interfaces/assignment', view: wide,
        actions: [{ wait: '.tabulator-row >> UPLINK' }, ...labRows],
        clip: [head, '#dialogAssignment .tabulator-header', '#dialogAssignment .tabulator-row'],
        /* the grid cuts the Device of WAN short; the next picture has it in full */
        expect: ['Interfaces: Assignments', 'WAN', 'ppp', 'UPLINK', { absent: 'MGMT' }, { absent: 'CLAT' }],
    },
    {
        id: '04-assignment-wan', set: 'vlan', file: 'opnsense-04-assignment-wan.png', title: '4. Make PPPoE your WAN: the WAN entry',
        url: '/ui/interfaces/assignment',
        actions: [{ wait: '.tabulator-row >> WAN' }, { click: '.tabulator-row >> WAN >> .command-edit' }, ...opened],
        clip: ['.modal.in .modal-header', id('row_interface.if')],
        expect: ['Edit Assignment', 'pppoe0 (vlan0.40) - YOUR_USERNAME'],
        after: cancel,
    },
    {
        id: '05-uplink', set: 'vlan', file: 'opnsense-05-uplink.png', title: '5. Set UPLINK',
        url: iface('opt2'),
        clip: [head, box('Basic configuration'), 'tr:has(#mtu)'],
        expect: ['Interfaces: [UPLINK]', { field: '#enable', is: true }, { field: '#type', is: 'None' }, { field: '#type6', is: 'None' },
            { field: '#mtu', is: '1508' }],
    },
    {
        id: '06-wan', set: 'vlan', file: 'opnsense-06-wan.png', title: '6. Set up the WAN: types and MTU',
        url: iface('wan'),
        clip: [head, box('Basic configuration'), 'tr:has(#mtu)'],
        expect: ['Interfaces: [WAN]', { field: '#enable', is: true }, 'pppoe0', { field: '#type', is: 'None' }, { field: '#type6', is: 'DHCPv6' },
            { field: '#mtu', is: '1508' }],
    },
    {
        id: '06-wan-dhcpv6', set: 'vlan', file: 'opnsense-06-wan-dhcpv6.png', title: '6. Set up the WAN: DHCPv6 client configuration',
        url: iface('wan'),
        actions: [{ hide: box('Basic configuration') }, { hide: box('Generic configuration') }],
        clip: [head, 'tr:has([id="dhcp6-ia-pd-send-hint"])'],
        expect: ['Interfaces: [WAN]', 'DHCPv6 client configuration', { field: '[id="dhcp6-ia-pd-len"]', is: '56' },
            { field: '#dhcp6prefixonly', is: true }, { field: '[id="dhcp6-ia-pd-send-hint"]', is: true }],
    },
    {
        id: '07-lan', file: 'opnsense-07-lan.png', title: '7. Share a /64 from your /56: the LAN',
        url: iface('lan'),
        actions: [{ hide: box('Basic configuration') }, { hide: box('Hardware settings') }, { hide: '#staticv4' }],
        clip: [head, 'tr:has([id="idassoc6-prefix-id--hex"])'],
        expect: ['Interfaces: [LAN]', { field: '#type6', is: 'Identity association' }, { field: 'select[name="idassoc6-interface"]', is: 'WAN' },
            { field: '[id="idassoc6-prefix-id--hex"]', is: '0' }],
    },
    {
        id: '07-dnsmasq-general', file: 'opnsense-07-dnsmasq-general.png', title: '7. Share a /64 from your /56: Dnsmasq sends router advertisements',
        url: '/ui/dnsmasq/settings#general',
        actions: dnsmasqGeneral,
        clip: [head, tabs, `table:has(${id('dnsmasq.dhcp.enable_ra')})`],
        expect: ['Services: Dnsmasq DNS & DHCP', 'Router advertisements', { field: id('dnsmasq.dhcp.enable_ra'), is: true }],
    },
    {
        id: '07-dnsmasq-range', file: 'opnsense-07-dnsmasq-range.png', title: '7. Share a /64 from your /56: the LAN entry of the DHCP ranges',
        url: '/ui/dnsmasq/settings#dhcpranges',
        actions: dnsmasqRange,
        clip: [dialog],
        expect: [{ field: id('range.interface'), is: 'LAN' }, { field: id('range.constructor'), is: 'LAN' }, { field: id('range.ra_mode'), is: 'slaac' }],
        after: cancel,
    },
    {
        id: '08-dns', file: 'opnsense-08-dns.png', title: '8. Set your DNS',
        url: '/system_general.php',
        actions: [{ hide: '.content-box:has(input[name=hostname])' }],
        clip: [head, '.content-box:has(input[name=dns1])', '.content-box:has(input[type=submit])'],
        expect: ['System: Settings: General', { field: 'input[name=dns1]', is: '2001:4860:4860::6464' }, { field: 'input[name=dns2]', is: '2001:4860:4860::64' },
            'Allow DNS server list to be overridden by DHCP/PPP on WAN', { field: 'input[name=dnsallowoverride]', is: false }, { absent: 'clat-opn' }],
    },
    {
        id: '09-unbound-forwarding', file: 'opnsense-09-unbound-forwarding.png', title: '9. Forward lookups to DNS64: Query Forwarding',
        url: '/ui/unbound/forward',
        actions: [{ wait: id('unbound.forwarding.enabled') }, { hide: '.content-box:has(.tabulator)' }],
        clip: [head, '.content-box:has(#frm_ForwardingSettings)', '.content-box:has(#reconfigureAct)'],
        expect: ['Services: Unbound DNS: Query Forwarding', 'Use System Nameservers', { field: id('unbound.forwarding.enabled'), is: true }],
    },
    {
        id: '09-unbound-general', file: 'opnsense-09-unbound-general.png', title: '9. Forward lookups to DNS64: DNS64 and DNSSEC stay off',
        url: '/ui/unbound/general',
        actions: [{ wait: id('unbound.general.dns64') }],
        clip: [head, id('row_unbound.general.dns64')],
        expect: ['Services: Unbound DNS: General', 'Enable DNSSEC Support', { field: id('unbound.general.dnssec'), is: false },
            'Enable DNS64 Support', { field: id('unbound.general.dns64'), is: false }],
    },
    {
        id: '10-overview', file: 'opnsense-10-overview.png', title: 'Check the MTU: Interfaces > Overview, where the Details buttons are',
        url: '/ui/interfaces/overview', view: wide,
        /* the Loopback row lists the routes to the box's own addresses, the lab's management address among them */
        actions: [{ wait: '#grid-overview .tabulator-row >> WAN (wan)' }, ...labRows, { hide: '#grid-overview .tabulator-row >> Loopback' }],
        clip: [head, '#grid-overview .tabulator-header', '#grid-overview .tabulator-row'],
        expect: ['Interfaces: Overview', 'WAN (wan)', 'pppoe0', 'UPLINK (opt2)', { absent: 'MGMT' }, { absent: 'CLAT' }, { absent: '10.99.0.' }],
    },
    {
        id: '10-mtu-wan', set: 'vlan', file: 'opnsense-10-mtu-wan.png', title: 'Check the MTU: the Details of WAN',
        url: '/ui/interfaces/overview', view: wide,
        actions: details('WAN (wan)'),
        clip: ['.modal.in .modal-header', '.modal.in tr >> mtu'],
        expect: ['WAN', 'pppoe0', 'mtu', '1500'],
        after: close,
    },
    {
        id: '10-mtu-uplink', set: 'vlan', file: 'opnsense-10-mtu-uplink.png', title: 'Check the MTU: the Details of UPLINK',
        url: '/ui/interfaces/overview', view: wide,
        actions: details('UPLINK (opt2)'),
        clip: ['.modal.in .modal-header', '.modal.in tr >> mtu'],
        expect: ['UPLINK', 'mtu', '1508'],
        after: close,
    },

    /* ---- Optional: 464XLAT, devices translate. The values are entered and not saved. ---- */
    {
        id: 'dt-1-dnsmasq-general', file: 'opnsense-dt-1-dnsmasq-general.png', title: 'Devices translate 1. Hand router advertisements to radvd: Dnsmasq, General',
        url: '/ui/dnsmasq/settings#general',
        actions: [...dnsmasqGeneral, { set: id('dnsmasq.dhcp.enable_ra'), to: false }],
        clip: [head, tabs, `table:has(${id('dnsmasq.dhcp.enable_ra')})`],
        expect: ['Router advertisements', { field: id('dnsmasq.dhcp.enable_ra'), is: false }],
    },
    {
        id: 'dt-1-dnsmasq-range', file: 'opnsense-dt-1-dnsmasq-range.png', title: 'Devices translate 1. Hand router advertisements to radvd: the LAN entry of the DHCP ranges, no RA mode',
        url: '/ui/dnsmasq/settings#dhcpranges',
        actions: [...dnsmasqRange, { set: id('range.ra_mode'), to: [] }],
        clip: [dialog],
        expect: [{ field: id('range.constructor'), is: 'LAN' }, { field: id('range.ra_mode'), is: '' }],
        after: cancel,
    },
    {
        id: 'dt-2-radvd', file: 'opnsense-dt-2-radvd.png', title: 'Devices translate 2. Announce PREF64: a new entry of Router Advertisements',
        url: '/ui/radvd/settings',
        actions: [{ wait: '.command-add' }, { click: '.command-add' }, ...opened, { click: '#show_advanced_dialog_dialogEntry' },
            { wait: id('entries.nat64prefix') }, { set: id('entries.interface'), to: 'LAN' }, { set: id('entries.mode'), to: 'Unmanaged' },
            { set: id('entries.nat64prefix'), to: '64:ff9b::/96' }],
        clip: [dialog],
        expect: [{ field: id('entries.enabled'), is: true }, { field: id('entries.interface'), is: 'LAN' }, { field: id('entries.mode'), is: 'Unmanaged' },
            'NAT64 prefix', { field: id('entries.nat64prefix'), is: '64:ff9b::/96' }],
        after: cancel,
    },
    {
        id: 'dt-3-option108', file: 'opnsense-dt-3-option108.png', title: 'Devices translate 3. Offer option 108: a new DHCP option of Dnsmasq',
        url: '/ui/dnsmasq/settings#dhcpoptions',
        actions: [{ wait: '#dhcpoptions.active .command-add' }, { click: '#dhcpoptions .command-add' }, ...opened,
            { set: id('option.type'), to: 'Set' }, { set: id('option.option'), to: 'ipv6-only [108]' }, { set: id('option.interface'), to: 'LAN' },
            { set: id('option.value'), to: '1800' }, { set: id('option.force'), to: false }],
        clip: [dialog],
        expect: [{ field: id('option.type'), is: 'Set' }, { field: id('option.option'), is: 'ipv6-only [108]' }, { field: id('option.interface'), is: 'LAN' },
            { field: id('option.value'), is: '1800' }, { field: id('option.force'), is: false }],
        after: cancel,
    },

    /* ---- Optional: 464XLAT, the router translates (os-clat) ---- */
    {
        id: 'rt-1-repository', file: 'opnsense-rt-1-repository.png', title: 'Router translates 1. After the line in the shell: System > Firmware > Status lists the repository',
        url: '/ui/core/firmware#status',
        actions: [{ wait: '#status td >> os-clat' }],
        clip: [head, tabs, '#status table'],
        expect: ['System: Firmware', 'Repositories', 'os-clat (Priority'],
    },
    {
        id: 'rt-2-plugins-link', set: 'fresh', file: 'opnsense-rt-2-plugins-link.png', title: 'Router translates 2. System > Firmware > Plugins: the link under the list',
        url: '/ui/core/firmware#plugins',
        actions: [{ wait: '#plugins-act' }],
        clip: [head, tabs, '#pluginlist'],
        expect: ['System: Firmware', 'Click to view the community plugins.', { absent: 'os-clat' }],
    },
    {
        id: 'rt-2-plugins', set: 'fresh', file: 'opnsense-rt-2-plugins.png', title: 'Router translates 2. System > Firmware > Plugins: os-clat among the community plugins',
        url: '/ui/core/firmware#plugins',
        actions: [{ wait: '#plugins-act' }, { click: '#plugins-act' }, ...plugins],
        clip: [head, tabs, '#pluginlist thead', '#pluginlist tr.plugin_entry >> os-clat'],
        expect: ['System: Firmware', 'os-clat', '464XLAT CLAT for IPv6-only uplinks', { absent: 'os-clat (installed)' }],
    },
    {
        id: 'rt-2-install', set: 'fresh', file: 'opnsense-rt-2-install.png', title: 'Router translates 2. The question after the + of os-clat',
        url: '/ui/core/firmware#plugins',
        actions: [{ wait: '#plugins-act' }, { click: '#plugins-act' }, ...plugins,
            /* only a plugin of another repository asks first; this selector matches nothing else */
            { click: '.act_install[data-package="os-clat"]:not([data-repository="OPNsense"])' }, ...opened],
        clip: [dialog],
        expect: ['Third party software', 'Install', 'Cancel'],
        after: cancel,
    },
    {
        id: 'rt-2-plugins-installed', file: 'opnsense-rt-2-plugins-installed.png', title: 'Router translates 2. System > Firmware > Plugins once os-clat is installed',
        url: '/ui/core/firmware#plugins',
        actions: plugins,
        clip: [head, tabs, '#pluginlist thead', '#pluginlist tr.plugin_entry >> os-clat'],
        expect: ['System: Firmware', 'os-clat (installed)', '464XLAT CLAT for IPv6-only uplinks'],
    },
    {
        id: 'rt-3-clat', file: 'opnsense-rt-3-clat.png', title: 'Router translates 3. Services > CLAT > Settings: the status',
        url: '/ui/clat',
        actions: [{ wait: '#frm_status td >> Active.' }],
        clip: [head, '.content-box:has(#frm_status)'],
        expect: ['Services: CLAT: Settings', 'Active.', 'pppoe0', '64:ff9b::/96 (DNS)', 'configured 1500, effective 1500, IPv4 1480, TCP MSS 1440', 'No findings.'],
    },
    {
        id: 'rt-3-clat-settings', file: 'opnsense-rt-3-clat-settings.png', title: 'Router translates 3. Services > CLAT > Settings: the settings, as installed',
        url: '/ui/clat',
        actions: [{ wait: '#frm_status td >> Active.' }, { hide: '.content-box:has(#frm_status)' }],
        clip: [head, '.content-box:has(#frm_general)', '.content-box:has(#reconfigureAct)'],
        expect: ['Services: CLAT: Settings', { field: id('clat.general.enabled'), is: 'Automatic' }],
    },
    {
        id: 'rt-4-clat-log', file: 'opnsense-rt-4-clat-log.png', title: 'Router translates 4. Services > CLAT > Log File, severity Informational',
        url: '/ui/diagnostics/log/core/clat', view: wide,
        actions: [{ set: '#severity_filter', to: 'Informational' }, { wait: '#grid-log .tabulator-row >> active' }],
        clip: [head, '#grid-log .tabulator-header', '#grid-log .tabulator-row:nth-child(-n+10)'],
        expect: ['Services: CLAT: Log File', 'Informational', 'state listening -> active', 'CLAT gateway: active'],
    },
];
