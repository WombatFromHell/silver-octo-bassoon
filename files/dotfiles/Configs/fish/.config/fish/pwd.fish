# Auto-expand 'pwdd' abbreviation to the current directory path
# Type 'pwdd' then Space/Enter to expand to $PWD

abbr --add pwdd --function __expand_pwd_abbr

function __expand_pwd_abbr --description "Expand 'pwdd' abbreviation to current directory"
    echo "$PWD"
end
