# Enable Powerlevel10k instant prompt. Should stay close to the top of ~/.zshrc.
# Initialization code that may require console input (password prompts, [y/n]
# confirmations, etc.) must go above this block; everything else may go below.
if [[ -r "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh" ]]; then
  source "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh"
fi

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
zplug "plugins/fasd", from:oh-my-zsh
zplug "zdharma/fast-syntax-highlighting"

# Install plugins if there are plugins that have not been installed
if ! zplug check; then
    zplug install
fi

# Then, source plugins and add commands to $PATH
zplug load

# User configuration

# To customize prompt, run `p10k configure` or edit ~/.p10k.zsh.
[[ ! -f ~/.p10k.zsh ]] || source ~/.p10k.zsh

source ~/.functions
source ~/.aliases
source ~/.environment

source ~/.config/broot/launcher/bash/br

# Key bindings for prompt navigation
bindkey "[D" backward-word
bindkey "[C" forward-word
bindkey "^[a" beginning-of-line
bindkey "^[e" end-of-line
