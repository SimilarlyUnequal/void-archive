import sys, re
text = sys.stdin.read()
urls = re.findall(r'https://[^\s]+', text)
for url in urls:
    print(url)
