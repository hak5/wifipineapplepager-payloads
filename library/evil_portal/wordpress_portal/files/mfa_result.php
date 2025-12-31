<?php
// mfa_result.php - Receives MFA result from Selenium script

$status = $_GET['status'] ?? '';
error_log("mfa_result.php called with status: " . $status);

// Accept MFA result statuses
$valid_statuses = ['mfa_success', 'mfa_failed'];

if (in_array($status, $valid_statuses)) {
    // Write status to file for mfa_handler.php to read
    file_put_contents('/tmp/mfa_result.txt', $status);
    error_log("MFA result written to file: " . $status);

    http_response_code(200);
    echo "MFA Status received: " . $status;
} else {
    error_log("Invalid MFA status received: " . $status);
    http_response_code(400);
    echo "Invalid MFA status: " . $status;
}
?>
