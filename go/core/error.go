package core

type UnivecError struct {
	IsUnivecError bool
	Sdk              string
	Code             string
	Msg              string
	Ctx              *Context
	Result           any
	Spec             any
}

func NewUnivecError(code string, msg string, ctx *Context) *UnivecError {
	return &UnivecError{
		IsUnivecError: true,
		Sdk:              "Univec",
		Code:             code,
		Msg:              msg,
		Ctx:              ctx,
	}
}

func (e *UnivecError) Error() string {
	return e.Msg
}
