/**
 * Google Voice Alerts Webhook
 *
 * Deploy this as a Google Apps Script Web App to check Gmail
 * for Google Voice notifications without needing your own server.
 *
 * Setup:
 * 1. Go to script.google.com
 * 2. Create new project, paste this code
 * 3. Deploy > New Deployment > Web App
 * 4. Execute as: Me, Who has access: Anyone
 * 5. Authorize when prompted (first time only)
 * 6. Copy the Web App URL for your pager webhook
 *
 * Security:
 * - Google Apps Script ALWAYS uses HTTPS (enforced by Google)
 * - The long random URL acts as an authentication token
 * - HTTPS encrypts the entire request, protecting against eavesdropping
 * - Never share your webhook URL publicly
 *
 * Requirements:
 * - Messages must be unread to be detected
 * - No Gmail labels or filters needed!
 *
 * Author: brAinphreAk
 * Version: 1.0
 * License: MIT
 */

// =============================================================================
// CONFIGURATION
// =============================================================================

const CONFIG = {
  // Maximum messages to check
  MAX_MESSAGES: 10,

  // Maximum preview length for texts/voicemails
  MAX_PREVIEW_LENGTH: 100
};

// =============================================================================
// MAIN WEBHOOK HANDLER
// =============================================================================

/**
 * Main webhook handler - called when pager polls
 * Accepts optional ?lastHash=xxx parameter for bandwidth optimization
 */
function doGet(e) {
  try {
    const lastHash = e.parameter.lastHash || '';
    const result = checkGoogleVoiceMessages(lastHash);
    return ContentService
      .createTextOutput(JSON.stringify(result))
      .setMimeType(ContentService.MimeType.JSON);
  } catch (error) {
    return ContentService
      .createTextOutput(JSON.stringify({
        hasMessages: false,
        count: 0,
        error: error.toString()
      }))
      .setMimeType(ContentService.MimeType.JSON);
  }
}

// =============================================================================
// CORE FUNCTIONS
// =============================================================================

/**
 * Check Gmail for Google Voice messages
 * @param {string} lastHash - Previous hash from pager (for bandwidth optimization)
 */
function checkGoogleVoiceMessages(lastHash) {
  // Search for unread emails from Google Voice senders (no label/filter needed!)
  const threads = GmailApp.search(
    'from:(txt.voice.google.com OR voice-noreply@google.com) is:unread',
    0,
    CONFIG.MAX_MESSAGES
  );

  if (threads.length === 0) {
    return {
      hasMessages: false,
      count: 0,
      msgHash: '',
      alertText: ''
    };
  }

  // First pass: collect message IDs for hash (lightweight)
  let hashParts = [];
  let unreadMessages = [];

  for (const thread of threads) {
    const gmailMessages = thread.getMessages();
    for (const msg of gmailMessages) {
      if (!msg.isUnread()) continue;
      hashParts.push(msg.getId());
      unreadMessages.push(msg);
    }
  }

  if (hashParts.length === 0) {
    return {
      hasMessages: false,
      count: 0,
      msgHash: '',
      alertText: ''
    };
  }

  // Create hash from message IDs
  const msgHash = Utilities.base64Encode(
    Utilities.computeDigest(Utilities.DigestAlgorithm.MD5, hashParts.join(','))
  ).substring(0, 16);

  // If hash unchanged, return minimal response (saves bandwidth)
  if (lastHash && msgHash === lastHash) {
    return {
      hasMessages: true,
      unchanged: true,
      count: unreadMessages.length,
      msgHash: msgHash
    };
  }

  // Hash changed - parse full message content
  const messages = [];
  for (const msg of unreadMessages) {
    const parsed = parseGoogleVoiceEmail(msg);
    if (parsed) {
      messages.push(parsed);
    }
  }

  if (messages.length === 0) {
    return {
      hasMessages: false,
      count: 0,
      msgHash: '',
      alertText: ''
    };
  }

  // Format alert text
  const alertText = formatAlertText(messages);

  return {
    hasMessages: true,
    count: messages.length,
    msgHash: msgHash,
    alertText: alertText
  };
}

/**
 * Parse a Google Voice email into structured data
 */
function parseGoogleVoiceEmail(msg) {
  const subject = msg.getSubject().toLowerCase();
  const body = msg.getPlainBody();
  const bodyLower = body.toLowerCase();
  const from = msg.getFrom().toLowerCase();

  let type = 'unknown';
  let phoneNumber = '';
  let preview = '';

  // Detect message type from subject, body, and sender
  // Check for missed calls
  if (subject.includes('missed call') || bodyLower.includes('missed call')) {
    type = 'missed_call';
    phoneNumber = extractPhoneNumber(msg.getSubject()) || extractPhoneNumber(body) || extractCallerName(msg.getSubject());
  }
  // Check for voicemails
  else if (subject.includes('voicemail') || bodyLower.includes('voicemail') ||
           bodyLower.includes('new voicemail') || bodyLower.includes('left you a voicemail')) {
    type = 'voicemail';
    phoneNumber = extractPhoneNumber(msg.getSubject()) || extractPhoneNumber(body) || extractCallerName(msg.getSubject());
    preview = extractPreview(body);
  }
  // Check for texts - including from txt.voice.google.com
  else if (subject.includes('text') || bodyLower.includes('text from') ||
           from.includes('txt.voice.google.com') || bodyLower.includes('sent you a text')) {
    type = 'text';
    phoneNumber = extractPhoneNumber(msg.getSubject()) || extractPhoneNumber(body) || extractCallerName(msg.getSubject());
    preview = extractPreview(body);
  }
  // Check sender for voice-noreply (could be any type)
  else if (from.includes('voice-noreply@google.com') || from.includes('voice.google.com')) {
    // Try to detect from body content
    if (bodyLower.includes('missed call') || bodyLower.includes('missed a call')) {
      type = 'missed_call';
    } else if (bodyLower.includes('voicemail') || bodyLower.includes('left a message')) {
      type = 'voicemail';
      preview = extractPreview(body);
    } else {
      // Default to text for unrecognized GV messages
      type = 'text';
      preview = extractPreview(body);
    }
    phoneNumber = extractPhoneNumber(body) || extractCallerName(msg.getSubject());
  }
  // Generic Google Voice check
  else if (subject.includes('google voice') || from.includes('google')) {
    if (bodyLower.includes('missed call')) {
      type = 'missed_call';
    } else if (bodyLower.includes('voicemail')) {
      type = 'voicemail';
      preview = extractPreview(body);
    } else {
      type = 'text';
      preview = extractPreview(body);
    }
    phoneNumber = extractPhoneNumber(body) || extractCallerName(msg.getSubject());
  }

  if (type === 'unknown') return null;

  return {
    type: type,
    phone: phoneNumber || 'Unknown',
    preview: preview
  };
}

// =============================================================================
// HELPER FUNCTIONS
// =============================================================================

/**
 * Extract phone number from text
 */
function extractPhoneNumber(text) {
  const patterns = [
    /\+1[- ]?\d{3}[- ]?\d{3}[- ]?\d{4}/,
    /\(\d{3}\)[- ]?\d{3}[- ]?\d{4}/,
    /\d{3}[- ]?\d{3}[- ]?\d{4}/,
    /\d{10,11}/
  ];

  for (const pattern of patterns) {
    const match = text.match(pattern);
    if (match) {
      return formatPhoneNumber(match[0]);
    }
  }
  return null;
}

/**
 * Extract caller name from subject line (for contacts without phone numbers)
 * Handles: "New voicemail from Joe Bertao", "Text from Joe Bertao", "Missed call from Joe Bertao"
 */
function extractCallerName(subject) {
  const patterns = [
    /voicemail from (.+)/i,
    /text from (.+)/i,
    /missed call from (.+)/i,
    /call from (.+)/i
  ];

  for (const pattern of patterns) {
    const match = subject.match(pattern);
    if (match && match[1]) {
      return match[1].trim();
    }
  }
  return null;
}

/**
 * Format phone number for display (XXX-XXX-XXXX)
 */
function formatPhoneNumber(phone) {
  const digits = phone.replace(/\D/g, '');
  if (digits.length === 11 && digits.startsWith('1')) {
    return digits.substring(1, 4) + '-' + digits.substring(4, 7) + '-' + digits.substring(7);
  } else if (digits.length === 10) {
    return digits.substring(0, 3) + '-' + digits.substring(3, 6) + '-' + digits.substring(6);
  }
  return phone;
}

/**
 * Extract message preview, removing Google boilerplate (but keeping user URLs)
 */
function extractPreview(body) {
  let text = body;

  // Only remove Google Voice URLs, not user-sent URLs
  text = text.replace(/<https?:\/\/voice\.google\.com[^>]*>/g, '');
  text = text.replace(/https?:\/\/voice\.google\.com[^\s]*/g, '');

  // Remove Google Voice footer/boilerplate
  const footerPatterns = [
    /To respond to this text message.*/is,
    /To listen to this voicemail.*/is,
    /play message.*/is,
    /call back.*/is,
    /YOUR ACCOUNT.*/is,
    /This email was sent.*/is,
    /Google LLC.*/is,
    /Do not share.*/is,
    /-{3,}.*/is,
    /\[image:.*?\]/ig
  ];

  for (const pattern of footerPatterns) {
    text = text.replace(pattern, '');
  }

  // Clean up whitespace
  text = text.replace(/\r\n/g, '\n');
  text = text.replace(/\n{3,}/g, '\n\n');
  text = text.trim();

  // Truncate if needed
  if (text.length > CONFIG.MAX_PREVIEW_LENGTH) {
    text = text.substring(0, CONFIG.MAX_PREVIEW_LENGTH) + '...';
  }

  return text;
}

/**
 * Format all messages into pager alert text
 */
function formatAlertText(messages) {
  // Count by type
  const counts = { missed_call: 0, voicemail: 0, text: 0 };
  for (const msg of messages) {
    counts[msg.type] = (counts[msg.type] || 0) + 1;
  }

  // Build header
  const parts = [];
  if (counts.missed_call > 0) parts.push(counts.missed_call + ' Call' + (counts.missed_call > 1 ? 's' : ''));
  if (counts.voicemail > 0) parts.push(counts.voicemail + ' VM' + (counts.voicemail > 1 ? 's' : ''));
  if (counts.text > 0) parts.push(counts.text + ' Text' + (counts.text > 1 ? 's' : ''));

  let text = '=== ' + messages.length + ' New: ' + parts.join(', ') + ' ===';

  // Add each message
  for (const msg of messages) {
    text += '\n\n';

    switch (msg.type) {
      case 'missed_call':
        text += 'Missed Call From ' + msg.phone;
        break;
      case 'voicemail':
        text += 'Voicemail From ' + msg.phone;
        if (msg.preview) {
          text += '\n' + msg.preview;
        }
        break;
      case 'text':
        text += 'Text From ' + msg.phone;
        if (msg.preview) {
          text += '\n' + msg.preview;
        }
        break;
    }
  }

  return text;
}

// =============================================================================
// TEST FUNCTION
// =============================================================================

/**
 * Test function - run this in the Apps Script editor to test
 */
function testCheck() {
  const result = checkGoogleVoiceMessages('');
  Logger.log(JSON.stringify(result, null, 2));
}

/**
 * Test bandwidth optimization - pass a hash to simulate cached state
 */
function testUnchanged() {
  // First call to get current hash
  const result1 = checkGoogleVoiceMessages('');
  Logger.log('First call (full response):');
  Logger.log(JSON.stringify(result1, null, 2));

  // Second call with same hash - should return minimal response
  if (result1.msgHash) {
    const result2 = checkGoogleVoiceMessages(result1.msgHash);
    Logger.log('Second call (should be unchanged):');
    Logger.log(JSON.stringify(result2, null, 2));
  }
}
