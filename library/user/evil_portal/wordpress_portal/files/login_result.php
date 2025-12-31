<?php
// login_result.php - Receives login result from Selenium script

$status = $_GET['status'] ?? '';
error_log("login_result.php called with status: " . $status);

// Accept all possible statuses
$valid_statuses = ['success_no_mfa', 'success_mfa_required', 'mfa_success', 'mfa_failed', 'failed', 'test'];

if (in_array($status, $valid_statuses)) {
    // Write status to file for helper.php to read
    file_put_contents('/tmp/login_result.txt', $status);
    error_log("Login result written to file: " . $status);

    http_response_code(200);
    echo "Status received: " . $status;
} else {
    error_log("Invalid status received: " . $status);
    http_response_code(400);
    echo "Invalid status: " . $status;
}
?>
