from pathlib import Path
from urllib.request import urlopen
from bs4 import BeautifulSoup

root = Path(__file__).resolve().parents[1] / "Vendor" / "ONNXRuntime" / "include"
root.mkdir(parents=True, exist_ok=True)
for page, output in [
    ("onnxruntime__c__api_8h_source.html", "onnxruntime_c_api.h"),
    ("onnxruntime__ep__c__api_8h_source.html", "onnxruntime_ep_c_api.h"),
    ("onnxruntime__error__code_8h_source.html", "onnxruntime_error_code.h"),
]:
    url = "https://onnxruntime.ai/docs/api/c/" + page
    html = urlopen(url, timeout=60).read()
    soup = BeautifulSoup(html, "html.parser")
    for number in soup.select("div.line .lineno"):
        number.decompose()
    lines = [line.get_text("", strip=False) for line in soup.select("div.line")]
    if len(lines) < 50:
        raise RuntimeError(f"Could not extract {page}: only {len(lines)} lines")
    (root / output).write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(f"{output}: {len(lines)} lines")
