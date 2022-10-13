# Enable Powerlevel10k instant prompt. Should stay close to the top of ~/.zshrc.
# Initialization code that may require console input (password prompts, [y/n]
# confirmations, etc.) must go above this block; everything else may go below.
if [[ -r "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh" ]]; then
  source "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh"
fi

# Profiling Start
# zmodload zsh/datetime
# setopt PROMPT_SUBST
# PS4='+$EPOCHREALTIME %N:%i> '

# logfile=$(mktemp zsh_profile.XXXXXXXX)
# echo "Logging to $logfile"
# exec 3>&2 2>$logfile

# setopt XTRACE

ZPLUG_INIT="$HOME/.zplug/init.zsh"

# Install zplug if not found
if [[ ! -f "$ZPLUG_INIT" ]]; then
  curl -sL --proto-redir -all,https https://raw.githubusercontent.com/zplug/installer/master/installer.zsh | zsh
fi

# Wait until init file is present before going on
t=0
while [[ ! -f "$ZPLUG_INIT" ]] && [[ $t -le 10 ]]; do
    sleep 0.1
    t=$(( t + 0.1 ))
done

source "$ZPLUG_INIT"

zplug "zplug/zplug", hook-build:"zplug --self-manage"

# Plugins
zplug "romkatv/powerlevel10k", as:theme, depth:1
zplug "lib/clipboard", from:oh-my-zsh
zplug "plugins/git", from:oh-my-zsh
zplug "lib/history", from:oh-my-zsh
# zplug "plugins/virtualenvwrapper", from:oh-my-zsh
zplug "plugins/fasd", from:oh-my-zsh
# zplug "zdharma/history-search-multi-word"
zplug "zsh-users/zsh-history-substring-search"
zplug "petervanderdoes/git-flow-completion"
zplug "zdharma/fast-syntax-highlighting", defer:1


# Install plugins if there are plugins that have not been installed
if ! zplug check; then
    zplug install
fi

# Then, source plugins and add commands to $PATH
zplug load

# unsetopt XTRACE
# exec 2>&3 3>&-
# User configuration

#To save every command before it is executed (this is different from bash's history -a solution):
setopt inc_append_history

#To retrieve the history file everytime history is called upon.
setopt share_history

# To customize prompt, run `p10k configure` or edit ~/.p10k.zsh.
[[ ! -f ~/.p10k.zsh ]] || source ~/.p10k.zsh

# Case-insensitive, partial-word completion
zstyle ':completion:*' matcher-list 'm:{a-z}={A-Z}' 'r:|[._-]=* r:|=*' 'l:|=* r:|=*'

# Key bindings for prompt navigation
bindkey "[D" backward-word
bindkey "[C" forward-word
bindkey "^[a" beginning-of-line
bindkey "^[e" end-of-line

# Key bindings for substring search
bindkey '^[[A' history-substring-search-up
bindkey '^[[B' history-substring-search-down

for script in ~/.functions \
	~/.aliases \
	~/.environment \
	~/.config/broot/launcher/bash/br; do
	[[ ! -f ${script} ]] || source ${script}
done

if command -v pyenv 1>/dev/null 2>&1; then
  eval "$(pyenv init -)"
fi
