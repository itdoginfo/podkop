def extend_key_value(current_value; new_value):
    if (current_value | type) == "array" then
        if (new_value | type) == "array" then
            current_value + new_value
        else
            current_value + [new_value]
        end
    else
        if (new_value | type) == "array" then
            [current_value] + new_value
        else
            [current_value, new_value]
        end
    end;