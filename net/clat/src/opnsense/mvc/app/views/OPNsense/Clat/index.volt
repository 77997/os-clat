{#
 # Copyright (C) 2026 os-clat contributors
 # All rights reserved.
 #
 # Redistribution and use in source and binary forms, with or without modification,
 # are permitted provided that the following conditions are met:
 #
 # 1. Redistributions of source code must retain the above copyright notice,
 #    this list of conditions and the following disclaimer.
 #
 # 2. Redistributions in binary form must reproduce the above copyright notice,
 #    this list of conditions and the following disclaimer in the documentation
 #    and/or other materials provided with the distribution.
 #
 # THIS SOFTWARE IS PROVIDED ``AS IS'' AND ANY EXPRESS OR IMPLIED WARRANTIES,
 # INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY
 # AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE
 # AUTHOR BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY,
 # OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
 # SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
 # INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
 # CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
 # ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
 # POSSIBILITY OF SUCH DAMAGE.
 #}

<script>
    $(document).ready(function() {
        /*
         * The status rows and the test result are plain text prepared by the backend. They are
         * inserted as they arrive (the API entity-escapes its replies to browser sessions); the
         * line breaks come from the style rule below.
         */
        function updateStatus() {
            ajaxGet('/api/clat/service/status', {}, function(data, status) {
                if (status === 'success' && data.clat && data.clat.text) {
                    setFormData('frm_status', {'status': data.clat.text});
                }
            });
            /*
             * The service buttons in the page head, with every refresh. After an Apply that starts the
             * service the Apply button asks for them once, at the moment the start returns; the daemon
             * has not written its pid file by then, and that answer says "stopped".
             */
            updateServiceControlUI('clat');
        }

        mapDataToFormUI({'frm_general': '/api/clat/settings/get'}).done(function() {
            formatTokenizersUI();
            $('.selectpicker').selectpicker('refresh');
        });
        updateStatus();

        $('#refreshAct').click(function() {
            updateStatus();
        });

        $('#reconfigureAct').SimpleActionButton({
            onPreAction: function() {
                const dfObj = $.Deferred();
                saveFormToEndpoint('/api/clat/settings/set', 'frm_general', dfObj.resolve, true, dfObj.reject);
                return dfObj;
            },
            onAction: function() {
                updateStatus();
                setTimeout(updateStatus, 5000);
            }
        });

        $('#testAct').SimpleActionButton({
            onAction: function(data, status) {
                /* also called when the request failed; the reply then has no text */
                if (status === 'success' && data && data.text !== undefined) {
                    $('#testResult').removeClass('hidden').html(data.text);
                } else {
                    $('#testResult').addClass('hidden').empty();
                }
                updateStatus();
            }
        });
    });
</script>

<style>
    #frm_status span[id^="status."],
    #testResult {
        white-space: pre-line;
    }
</style>

<div class="content-box __mb">
    {{ partial('layout_partials/base_form', ['fields': statusForm, 'id': 'frm_status']) }}
    <div class="col-md-12 __mt __mb">
        <button class="btn btn-default" id="refreshAct" type="button"><b>{{ lang._('Refresh') }}</b></button>
        <button class="btn btn-default" id="testAct" data-endpoint="/api/clat/service/test" data-label="{{ lang._('Run tests') }}" type="button"></button>
    </div>
    <div class="col-md-12">
        <div class="alert alert-info hidden" role="alert" id="testResult"></div>
    </div>
</div>

<div class="content-box">
    {{ partial('layout_partials/base_form', ['fields': generalForm, 'id': 'frm_general']) }}
</div>

{{ partial('layout_partials/base_apply_button', {'data_endpoint': '/api/clat/service/reconfigure', 'data_service_widget': 'clat'}) }}
