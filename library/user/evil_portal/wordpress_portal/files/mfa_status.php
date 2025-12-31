<?php
// mfa_status.php - Receives MFA status from Selenium script

$required = $_GET['required'] ?? '';

if ($required === 'true' || $required === 'false') {
    // Write status to file for helper.php to read
    file_put_contents('/tmp/mfa_status.txt', $required);
    error_log("MFA status received: " . $required);

    http_response_code(200);
    echo "Status received: " . $required;
} else {
    http_response_code(400);
    echo "Invalid status";
}
?>
