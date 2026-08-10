$utf8 = New-Object System.Text.UTF8Encoding $false
$text = [IO.File]::ReadAllText('src/index.html')
$text = $text.Replace('keychain-2db', 'keychain-2.db')
[IO.File]::WriteAllText('src/index.html', $text, $utf8)

$text2 = [IO.File]::ReadAllText('Qilong-AI-FangGao-bate1-a3760cf8e23bf985c0d1467120af414784f61402/src/index.html')
$text2 = $text2.Replace('keychain-2db', 'keychain-2.db')
[IO.File]::WriteAllText('Qilong-AI-FangGao-bate1-a3760cf8e23bf985c0d1467120af414784f61402/src/index.html', $text2, $utf8)
