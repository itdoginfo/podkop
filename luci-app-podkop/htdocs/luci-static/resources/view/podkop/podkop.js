'use strict';
'require view';
'require form';
'require network';
'require view.podkop.configSection as configSection';
'require view.podkop.diagnosticTab as diagnosticTab';
'require view.podkop.additionalTab as additionalTab';
'require view.podkop.utils as utils';

return view.extend({
    async render() {
        document.head.insertAdjacentHTML('beforeend', `
            <style>
                .cbi-value {
                    margin-bottom: 10px !important;
                }

                #diagnostics-status .table > div {
                    background: var(--background-color-primary);
                    border: 1px solid var(--border-color-medium);
                    border-radius: var(--border-radius);
                }

                #diagnostics-status .table > div pre,
                #diagnostics-status .table > div div[style*="monospace"] {
                    color: var(--color-text-primary);
                }

                #diagnostics-status .alert-message {
                    background: var(--background-color-primary);
                    border-color: var(--border-color-medium);
                }

                #cbi-podkop:has(.cbi-tab-disabled[data-tab="basic"]) #cbi-podkop-extra {
                    display: none;
                }
            </style>
        `);

        const m = new form.Map('podkop', _(''), null, ['main', 'extra']);

        // Main Section
        const mainSection = m.section(form.TypedSection, 'main');
        mainSection.anonymous = true;
        configSection.createConfigSection(mainSection, m, network);

        // Additional Settings Tab (main section)
        additionalTab.createAdditionalSection(mainSection, network);

        // Diagnostics Tab (main section)
        diagnosticTab.createDiagnosticsSection(mainSection);
        const map_promise = m.render().then(node => {
            // Set up diagnostics event handlers
            diagnosticTab.setupDiagnosticsEventHandlers(node);

            // Start critical error polling for all tabs
            utils.startErrorPolling();

            // Add event listener to keep error polling active when switching tabs
            const tabs = node.querySelectorAll('.cbi-tabmenu');
            if (tabs.length > 0) {
                tabs[0].addEventListener('click', function (e) {
                    const tab = e.target.closest('.cbi-tab');
                    if (tab) {
                        // Ensure error polling continues when switching tabs
                        utils.startErrorPolling();
                    }
                });
            }

            // Add visibility change handler to manage error polling
            document.addEventListener('visibilitychange', function () {
                if (document.hidden) {
                    utils.stopErrorPolling();
                } else {
                    utils.startErrorPolling();
                }
            });

            return node;
        });

        // Extra Section
        const extraSection = m.section(form.TypedSection, 'extra', _('Extra configurations'));
        extraSection.anonymous = false;
        extraSection.addremove = true;
        extraSection.addbtntitle = _('Add Section');
        extraSection.multiple = true;
        configSection.createConfigSection(extraSection, m, network);

        return map_promise;
    }
});