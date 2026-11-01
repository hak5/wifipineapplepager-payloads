import platform
import os
from pathlib import Path

def get_os_template():
    """
    Detects the current operating system and maps it to the corresponding
    HTML template file in web/templates.

    Returns:
        str: The absolute path to the template file.
    """
    os_name = platform.system().lower()
    templates_dir = Path(__file__).parent.parent / "web" / "templates"

    # Mapping of OS name to template filename
    os_map = {
        "windows": "windows.html",
        "linux": "linux.html",
        "darwin": "darwin.html"
    }

    template_file = os_map.get(os_name, "default.html")
    template_path = templates_dir / template_file

    # Fallback if the specific template doesn't exist
    if not template_path.exists():
        template_path = templates_dir / "default.html"

    return str(template_path.absolute())

def serve_portal():
    """
    Reads the content of the OS-specific template and returns it as a string
    to be served by the web server.

    Returns:
        str: The HTML content of the portal.
    """
    template_path = get_os_template()
    try:
        with open(template_path, 'r', encoding='utf-8') as f:
            return f.read()
    except Exception as e:
        return f"<h1>Error</h1><p>Could not load portal template: {str(e)}</p>"

if __name__ == "__main__":
    # Simple test for local verification
    print(f"Detected OS Template: {get_os_template()}")
    print("--- Content ---")
    print(serve_portal())
