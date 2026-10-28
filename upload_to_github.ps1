# 把 MemoNest 项目上传到 GitHub
# 用法：
#   .\upload_to_github.ps1 -Repo "用户名/仓库名" -Token "ghp_xxx"
#   .\upload_to_github.ps1 -Repo "用户名/仓库名" -Token "ghp_xxx" -Public
param(
    [Parameter(Mandatory = $true)][string]$Repo,
    [Parameter(Mandatory = $true)][string]$Token,
    [string]$Branch = "main",
    [switch]$Public
)

$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    throw "未找到 git，请先安装 https://git-scm.com/download/win"
}
if ($Repo -notmatch '^[^/]+/[^/]+$') {
    throw "仓库格式应为 用户名/仓库名，例如 octocat/memo-nest"
}

$owner, $name = $Repo.Split('/')
$headers = @{
    Authorization          = "token $Token"
    "User-Agent"           = "MemoNest"
    Accept                 = "application/vnd.github+json"
    "X-GitHub-Api-Version" = "2022-11-28"
}

Set-Location $PSScriptRoot

# 1. 仓库不存在则创建
try {
    Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo" -Headers $headers | Out-Null
    Write-Host "仓库已存在：$Repo"
} catch {
    Write-Host "创建仓库：$Repo"
    $me = Invoke-RestMethod -Uri "https://api.github.com/user" -Headers $headers
    $body = @{
        name        = $name
        description = "MemoNest 小便签式 Markdown 备忘录"
        private     = (-not $Public)
        auto_init   = $false
    } | ConvertTo-Json

    if ($owner -eq $me.login) {
        Invoke-RestMethod -Uri "https://api.github.com/user/repos" -Method Post -Headers $headers -Body $body | Out-Null
    } else {
        Invoke-RestMethod -Uri "https://api.github.com/orgs/$owner/repos" -Method Post -Headers $headers -Body $body | Out-Null
    }
}

# 2. 初始化本地仓库并提交
if (-not (Test-Path ".git")) {
    git init -b $Branch | Out-Null
}
git add -A
git -c user.name="MemoNest" -c user.email="memonest@localhost" commit -m "MemoNest 便签备忘录" 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Host "没有新的变更需要提交"
}

# 3. 设置不带 Token 的 origin，再用临时地址推送
$plainUrl = "https://github.com/$Repo.git"
$existing = git remote
if ($existing -match '(^|\s)origin(\s|$)') {
    git remote set-url origin $plainUrl
} else {
    git remote add origin $plainUrl
}

Write-Host "推送代码到 $Repo（$Branch 分支）…"
$pushUrl = "https://x-access-token:$Token@github.com/$Repo.git"
git push $pushUrl "HEAD:$Branch"
if ($LASTEXITCODE -ne 0) {
    throw "推送失败。请检查 Token 权限（需要 repo）、仓库地址和分支设置。"
}

Write-Host ""
Write-Host "完成：https://github.com/$Repo" -ForegroundColor Green
