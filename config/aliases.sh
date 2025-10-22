# Demo Config Aliases
alias ll='ls -alF'
alias la='ls -A'
alias l='ls -CF'
alias ..='cd ..'
alias ...='cd ../..'
alias grep='grep --color=auto'
alias fgrep='fgrep --color=auto'
alias egrep='egrep --color=auto'

# Project specific aliases
alias demo-config='cd /Users/michaelfoster/Desktop/github/red_hat_github/demo-config'
alias logs='tail -f logs/setup.log'
alias config='cd config'
alias scripts='cd scripts'

# Git aliases
alias gs='git status'
alias ga='git add'
alias gc='git commit'
alias gp='git push'
alias gl='git log --oneline'
alias gd='git diff'

# System aliases
alias ports='netstat -tulpn | grep LISTEN'
alias myip='curl -s https://ipinfo.io/ip'
alias weather='curl -s wttr.in'
