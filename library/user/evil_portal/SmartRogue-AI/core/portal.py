import platform
import os
from pathlib import Path

def get_os_template(user_agent=""):
    """
    Detects the client's operating system from the User-Agent string 
    and maps it to the corresponding HTML template file in web/templates.

    Args:
        user_agent (str): The HTTP User-Agent header from the client request.

    Returns:
        str: The absolute path to the template file.
    """
    templates_dir = Path(__file__).parent.parent / "web" / "templates"
    ua_lower = user_agent.lower()

    # Determine client OS based on User-Agent
    if "iphone" in ua_lower or "ipad" in ua_lower or "ios" in ua_lower:
        template_file = "ios.html"
    elif "android" in ua_lower:
        template_file = "android.html"
    elif "windows" in ua_lower:
        template_file = "windows.html"
    elif "macintosh" in ua_lower or "mac os x" in ua_lower:
        template_file = "darwin.html"
    elif "linux" in ua_lower:
        template_file = "linux.html"
    else:
        template_file = "default.html"

    template_path = templates_dir / template_file

    # Fallback if the specific template doesn't exist
    if not template_path.exists():
        template_path = templates_dir / "default.html"

    return str(template_path.absolute())

def serve_portal(user_agent=""):
    """
    Reads the content of the OS-specific template based on client User-Agent 
    and returns it as a string to be served by the web server.

    Args:
        user_agent (str): The HTTP User-Agent header from the client request.

    Returns:
        str: The HTML content of the portal.
    """
    template_path = get_os_template(user_agent)
    try:
        with open(template_path, 'r', encoding='utf-8') as f:
            return f.read()
    except Exception as e:
        return f"<h1>Error</h1><p>Could not load portal template: {str(e)}</p>"

if __name__ == "__main__":
    # Test local simulation with a dummy iOS User-Agent
    test_ua = "Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) AppleWebKit/605.1.15"
    print(f"Tested User-Agent: {test_ua}")
    print(f"Selected Template Path: {get_os_template(test_ua)}")
    print("--- Content Preview ---")
    print(serve_portal(test_ua)[:150]) # Show first 150 chars of the template
