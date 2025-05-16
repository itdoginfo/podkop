'use strict';
'require baseclass';

function validateUrl(url, protocols = ['http:', 'https:']) {
    try {
        const parsedUrl = new URL(url);
        if (!protocols.includes(parsedUrl.protocol)) {
            return _('URL must use one of the following protocols: ') + protocols.join(', ');
        }
        return true;
    } catch (e) {
        return _('Invalid URL format');
    }
}

return baseclass.extend({
    validateUrl
}); 