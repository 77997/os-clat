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

namespace OPNsense\Clat;

use OPNsense\Base\BaseModel;
use OPNsense\Base\Messages\Message;

/**
 * Class Clat
 * @package OPNsense\Clat
 */
class Clat extends BaseModel
{
    /**
     * {@inheritdoc}
     */
    public function performValidation($validateFullModel = false)
    {
        $messages = parent::performValidation($validateFullModel);
        $general = $this->general;

        $prefix = $general->prefix->getValue();
        $prefixId = $general->prefix_id->getValue();
        $address = $general->address->getValue();
        $ipv4Clat = $general->ipv4_clat->getValue();
        $addressChanged = $validateFullModel || $general->address->isFieldChanged();

        if ($prefix !== '' && ($validateFullModel || $general->prefix->isFieldChanged())) {
            /* the prefix lengths of RFC 6052 */
            if (!in_array(explode('/', $prefix)[1] ?? '', ['32', '40', '48', '56', '64', '96'], true)) {
                $messages->appendMessage(new Message(
                    gettext('The NAT64 prefix length must be 32, 40, 48, 56, 64 or 96.'),
                    'general.prefix'
                ));
            }
        }

        if ($address !== '' && $prefixId !== '' && ($addressChanged || $general->prefix_id->isFieldChanged())) {
            $messages->appendMessage(new Message(
                gettext('Set either a prefix ID or a full address, not both.'),
                'general.prefix_id'
            ));
        }

        /* an address the field validation rejects is not looked at here */
        if ($addressChanged && filter_var($address, FILTER_VALIDATE_IP, FILTER_FLAG_IPV6) !== false) {
            if (ord(inet_pton($address)[15]) & 1) {
                $messages->appendMessage(new Message(
                    gettext('The CLAT address must be even; the next address is used by the translator.'),
                    'general.address'
                ));
            }
        }

        if (
            $ipv4Clat !== '' && $ipv4Clat === $general->ipv4_tayga->getValue() &&
            ($validateFullModel || $general->ipv4_clat->isFieldChanged() || $general->ipv4_tayga->isFieldChanged())
        ) {
            $messages->appendMessage(new Message(
                gettext('The translator address must differ from the CLAT address.'),
                'general.ipv4_tayga'
            ));
        }

        return $messages;
    }
}
