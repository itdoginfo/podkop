'use strict';
'require baseclass';
'require ui';
'require fs';
'require view.podkop.constants as constants';

// Flag to track if this is the first error check
let isInitialCheck = true;

// Set to track which errors we've already seen
const lastErrorsSet = new Set();

// Timer for periodic error polling
let errorPollTimer = null;

// Helper function to fetch errors from the podkop command
async function getPodkopErrors() {
    return new Promise(resolve => {
        safeExec('/usr/bin/podkop', ['check_logs'], 'P0_PRIORITY', result => {
            if (!result || !result.stdout) return resolve([]);

            const logs = result.stdout.split('\n');
            const errors = logs.filter(log =>
                log.includes('[critical]')
            );

            resolve(errors);
        });
    });
}

// Show error notification to the user
function showErrorNotification(error, isMultiple = false) {
    const notificationContent = E('div', { 'class': 'alert-message error' }, [
        E('pre', { 'class': 'error-log' }, error)
    ]);

    ui.addNotification(null, notificationContent);
}

// Helper function for command execution with prioritization
function safeExec(command, args, priority, callback, timeout = constants.COMMAND_TIMEOUT) {
    // Default to highest priority execution if priority is not provided or invalid
    let schedulingDelay = constants.COMMAND_SCHEDULING.P0_PRIORITY;

    // If priority is a string, try to get the corresponding delay value
    if (typeof priority === 'string' && constants.COMMAND_SCHEDULING[priority] !== undefined) {
        schedulingDelay = constants.COMMAND_SCHEDULING[priority];
    }

    const executeCommand = async () => {
        try {
            const controller = new AbortController();
            const timeoutId = setTimeout(() => controller.abort(), timeout);

            const result = await Promise.race([
                fs.exec(command, args),
                new Promise((_, reject) => {
                    controller.signal.addEventListener('abort', () => {
                        reject(new Error('Command execution timed out'));
                    });
                })
            ]);

            clearTimeout(timeoutId);

            if (callback && typeof callback === 'function') {
                callback(result);
            }

            return result;
        } catch (error) {
            console.warn(`Command execution failed or timed out: ${command} ${args.join(' ')}`);
            const errorResult = { stdout: '', stderr: error.message, error: error };

            if (callback && typeof callback === 'function') {
                callback(errorResult);
            }

            return errorResult;
        }
    };

    if (callback && typeof callback === 'function') {
        setTimeout(executeCommand, schedulingDelay);
        return;
    }
    else {
        return executeCommand();
    }
}

// Check for critical errors and show notifications
async function checkForCriticalErrors() {
    try {
        const errors = await getPodkopErrors();

        if (errors && errors.length > 0) {
            // Filter out errors we've already seen
            const newErrors = errors.filter(error => !lastErrorsSet.has(error));

            if (newErrors.length > 0) {
                // On initial check, just store errors without showing notifications
                if (!isInitialCheck) {
                    // Show each new error as a notification
                    newErrors.forEach(error => {
                        showErrorNotification(error, newErrors.length > 1);
                    });
                }

                // Add new errors to our set of seen errors
                newErrors.forEach(error => lastErrorsSet.add(error));
            }
        }

        // After first check, mark as no longer initial
        isInitialCheck = false;
    } catch (error) {
        console.error('Error checking for critical messages:', error);
    }
}

// Start polling for errors at regular intervals
function startErrorPolling() {
    if (errorPollTimer) {
        clearInterval(errorPollTimer);
    }

    // Reset initial check flag to make sure we show errors
    isInitialCheck = false;

    // Immediately check for errors on start
    checkForCriticalErrors();

    // Then set up periodic checks
    errorPollTimer = setInterval(checkForCriticalErrors, constants.ERROR_POLL_INTERVAL);
}

// Stop polling for errors
function stopErrorPolling() {
    if (errorPollTimer) {
        clearInterval(errorPollTimer);
        errorPollTimer = null;
    }
}

return baseclass.extend({
    startErrorPolling,
    stopErrorPolling,
    checkForCriticalErrors,
    safeExec
}); 