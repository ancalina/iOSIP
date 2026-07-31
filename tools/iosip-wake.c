extern void GSEventSetBacklightLevel(float level);
extern void GSEventResetIdleTimer(void);
extern void SBSUndimScreen(void);

int main(void)
{
    GSEventResetIdleTimer();
    GSEventSetBacklightLevel(1.0f);
    SBSUndimScreen();
    return 0;
}
