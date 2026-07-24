# Shortcuts
alias copyssh="pbcopy < $HOME/.ssh/id_ed25519.pub"
alias reloadshell="source $HOME/.zshrc"
alias reloaddns="dscacheutil -flushcache && sudo killall -HUP mDNSResponder"
alias pstorm='open -a /Applications/PhpStorm.app "`pwd`"'
alias code='open -a "/Applications/Visual Studio Code.app" "`pwd`"'
alias shrug="echo '¯\_(ツ)_/¯' | pbcopy"
alias c="clear"
alias python=python3

# Directories
alias dotfiles="code $DOTFILES"
alias library="cd $HOME/Library"
alias web="cd $HOME/Code"

# Laravel
alias pfresh="php artisan migrate:fresh --seed"
alias sfresh="sail artisan migrate:fresh --seed"
alias pseed="php artisan db:seed"
alias sseed="sail artisan db:seed"
alias sail='[ -f sail ] && bash sail || bash vendor/bin/sail'
alias ptinker="php artisan tinker"
alias pserve="php artisan serve"

# PHP
alias cfresh="rm -rf vendor/ composer.lock && composer i"

# JS
alias bi="bun i"
alias bii="bun i -y"
alias pf="pnpm run fresh"
alias pi="pnpm i"
alias pu="pnpm up"
alias pid="pnpm i -D"
alias bid="bun i -D"

# JS/TS Stacks
alias b="bun"
alias bc="bun commit"
alias br="bun run release"
alias bd="bun run dev"
alias bdc="bun buddy dev:components"
alias bb="bun run build"
alias bl="bun lint"
alias blf="bun lint:fix"
alias bf="buddy fresh"

# Git
alias gst="git status"
alias gb="git branch"
alias gc="git checkout"
alias gl="git log --oneline --decorate --color"
alias amend="git add . && git commit --amend --no-edit"
alias commit="git add . && git commit -m"
alias diff="git diff"
alias force="git push --force"
alias nah="git clean -df && git reset --hard"
alias pop="git stash pop"
alias pull="git pull"
alias push="git push"
alias resolve="git add . && git commit --no-edit"
alias stash="git stash -u"
alias unstage="git restore --staged ."
alias wip="commit 'chore: wip'; push"

# Show/hide hidden files in Finder
alias show="defaults write com.apple.finder AppleShowAllFiles -bool true && killall Finder"
alias hide="defaults write com.apple.finder AppleShowAllFiles -bool false && killall Finder"

# Fix/Unstick macOS Touch Bar when it freezes
alias ft="killall ControlStrip && pkill 'Touch Bar agent'"

# IP addresses
alias ip="curl https://diagnostic.opendns.com/myip ; echo"
alias localip="ifconfig -a | grep -o 'inet6\? \(addr:\)\?\s\?\(\(\([0-9]\+\.\)\{3\}[0-9]\+\)\|[a-fA-F0-9:]\+\)' | awk '{ sub(/inet6? (addr:)? ?/, \"\"); print }'"

# Empty the Trash on all mounted volumes and the main HDD
# Also, clear Apple’s System Logs to improve shell startup speed
alias emptytrash="sudo rm -rfv /Volumes/*/.Trashes; sudo rm -rfv ~/.Trash; sudo rm -rfv /private/var/log/asl/*.asl"

# Enable aliases to be sudo’ed
alias sudo='sudo '
