<?php namespace evilportal;

class MyPortal extends Portal
{
    public function handleAuthorization()
    {
        if (isset($this->request->target)) {
            parent::handleAuthorization();
        }
    }

    public function authorizeClient($clientIP)
    {
        return parent::authorizeClient($clientIP);
    }

    public function onSuccess()
    {
        $this->notify("GARMR: Client authorized after capture");
    }
}
